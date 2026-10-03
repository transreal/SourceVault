(* ::Package:: *)

(* ============================================================
   SourceVault_knowledgegraph.wl -- \:767a\:8868\:7528\:77e5\:8b58\:30b0\:30e9\:30d5 (KG) \:5c64

   This file is encoded in UTF-8.
   Load via: Block[{$CharacterEncoding = "UTF-8"}, Get["SourceVault_knowledgegraph.wl"]]

   \:4ed5\:69d8\:66f8: SlideWorkflow_info/design/slide_knowledge_graph_spec_v0_1.md

   \:4f4d\:7f6e\:3065\:3051:
     \:8ad6\:6587 1 \:672c (\:307e\:305f\:306f\:8907\:6570) \:306e\:5185\:5bb9\:3068\:5468\:8fba\:77e5\:8b58\:3092\:300c\:9806\:5e8f\:30fb\:96e3\:6613\:5ea6\:3064\:304d\:306e\:77e5\:8b58\:30b0\:30e9\:30d5\:300d\:3068\:3057\:3066
     \:4fdd\:6301\:3057\:3001\:8074\:304d\:624b (\:7406\:89e3\:5ea6\:30fb\:524d\:63d0\:77e5\:8b58) \:3068\:6642\:9593 (\:679a\:6570\:30fb\:5206) \:3092\:4e0e\:3048\:308b\:3068
       I  \:77e5\:8b58\:30b0\:30e9\:30d5 (Nodes / Edges: \:95a2\:9023\:5ea6 + \:56e0\:679c/\:5e74\:4ee3/\:5c0e\:51fa/\:96e3\:6613\:5ea6\:306e\:9806\:5e8f\:8fba)
       II \:5468\:8fba\:77e5\:8b58\:30ce\:30fc\:30c9\:306e\:8ffd\:52a0\:3068\:5171\:6709 background \:5c64\:3078\:306e\:9023\:7d50
       III \:6700\:5c0f\:5168\:57df\:9806\:5e8f\:6728 (\:8907\:6570\:5019\:88dc: \:53f3\:80cc\:9aa8\:8caa\:6b32 = \:7dda\:5f62\:62e1\:5f35\:306e\:968e\:5c64\:5206\:5272)
       IV \:968e\:5c64\:3054\:3068\:306e\:6982\:8981 + \:7834\:7dbb\:691c\:8a3c (\:9806\:5e8f\:9055\:53cd / \:524d\:63d0\:6b20\:843d / \:5faa\:74b0)
       V  \:679a\:6570\:30fb\:6642\:9593\:306b\:3088\:308b\:8a70\:3081\:8fbc\:307f (packing) \:3068\:679d\:5208\:308a (pruning)
       VI \:30c8\:30dd\:30ed\:30b8\:30ab\:30eb\:9806\:306e\:30b7\:30ea\:30a2\:30e9\:30a4\:30ba \[RightArrow] \:8a00\:8a9e\:5225\:30a2\:30a6\:30c8\:30e9\:30a4\:30f3 \[RightArrow] \:30b7\:30ca\:30ea\:30aa md
     \:3092\:6c7a\:5b9a\:7684\:306b\:8a08\:7b97\:3059\:308b\:3002\:751f\:6210\:7269\:306f\:30b9\:30e9\:30a4\:30c9\:3067\:306f\:306a\:304f KG (\:30b9\:30e9\:30a4\:30c9\:306f KG \:306e\:6295\:5f71)\:3002

   \:8cc7\:7523\:306e\:518d\:5229\:7528 (oops-ml \:7531\:6765\:306e\:30b0\:30e9\:30d5\:67a0\:7d44\:307f):
     - \:8fba\:30ec\:30b3\:30fc\:30c9\:306f SourceVault_oopsseed.wl \:306e TopicItemGraph \:3068\:540c\:5f62
       {From, To, EdgeKind, Weight, EvidenceRefs} (+ Order / OrderKind / Confidence)\:3002
       SourceVaultKGToTopicItemGraph \:3067 SourceVaultOOPSTopicGraphPlot \:306b\:305d\:306e\:307e\:307e\:6e21\:305b\:308b\:3002
     - \:5468\:8fba\:77e5\:8b58 (background) \:30ce\:30fc\:30c9\:306f bg:<slug> \:306e\:5171\:6709 ID \:3067\:8907\:6570\:8ad6\:6587\:304b\:3089\:53c2\:7167\:3055\:308c\:308b
       (Knowledge Home \:306e svtopic:kh:* \:3068\:540c\:3058\:300c\:8ffd\:8a18\:3057\:3066\:5171\:6709\:3059\:308b\:300d\:8003\:3048\:65b9)\:3002
     - \:904e\:53bb\:30c7\:30c3\:30ad\:306e\:518d\:5229\:7528\:306f SourceVault_kb.wl (Graph-RAG) \:306e\:691c\:7d22\:3067 slide \:8cc7\:7523\:3092\:63d0\:6848\:3059\:308b\:3002

   service-loadable \:5236\:7d04:
     FrontEnd / Notebook / NBAccess / UI \:4f9d\:5b58\:3092\:6301\:305f\:306a\:3044\:3002\:4ed6 SourceVault \:30e2\:30b8\:30e5\:30fc\:30eb\:306f
     DownValues guard \:4ed8\:304d\:306e\:5f31\:7d50\:5408 (CoreRoot / KB / OOPS plot) \:306e\:307f\:3002
     \:5358\:4f53 Get \:3067\:3082\:52d5\:304f ($SourceVaultKGRoot \:3092\:4e0e\:3048\:308c\:3070\:30c6\:30b9\:30c8\:53ef\:80fd)\:3002
     LLM \:306f\:547c\:3070\:306a\:3044: \:30d7\:30ed\:30f3\:30d7\:30c8\:306f\:7d14\:95a2\:6570\:3067\:7d44\:307f\:7acb\:3066\:3001\:5fdc\:7b54 JSON \:306f SourceVaultKGFromJSON /
     SourceVaultKGMerge \:3067\:691c\:8a3c\:3057\:3066\:53d6\:308a\:8fbc\:3080 (\:5b9f\:884c\:306f\:30a8\:30fc\:30b8\:30a7\:30f3\:30c8\:5074\:306e\:8cac\:52d9)\:3002

   privacy:
     KG / \:30ce\:30fc\:30c9\:306f PrivacyLevel (0.0-1.0, \:5927\:304d\:3044\:307b\:3069\:53b3\:683c) \:3092\:6301\:3064\:3002\:65e2\:5b9a 0.0 (\:516c\:958b\:8ad6\:6587)\:3002
     \:30a2\:30a6\:30c8\:30e9\:30a4\:30f3\:5316\:306f "ReleaseCeiling" (\:65e2\:5b9a 0.5) \:3092\:8d85\:3048\:308b\:30ce\:30fc\:30c9\:3092 fail-closed \:3067\:843d\:3068\:3059\:3002
   ============================================================ *)

BeginPackage["SourceVault`"]

$SourceVaultKGRoot::usage = "$SourceVaultKGRoot \:306f\:77e5\:8b58\:30b0\:30e9\:30d5\:5c64\:306e\:4fdd\:5b58\:5148 (Automatic = SourceVaultCoreRoot[]/knowledgegraph\:3001\:7121\:3051\:308c\:3070 LOCALAPPDATA/SourceVault/knowledgegraph)\:3002\:30c6\:30b9\:30c8\:3067\:306f\:30c7\:30a3\:30ec\:30af\:30c8\:30ea\:3092\:4e0e\:3048\:3066\:9694\:96e2\:3059\:308b\:3002";
$SourceVaultKGEdgeKinds::usage = "$SourceVaultKGEdgeKinds \:306f\:8fba\:7a2e\:5225\:306e\:8868\:3002<|kind -> <|\"Order\" (From \:3092 To \:3088\:308a\:5148\:306b\:63d0\:793a\:3059\:308b\:9806\:5e8f\:5236\:7d04\:304b), \"OrderKind\" (Difficulty|Temporal|Derivation|Narrative|Causal|Hierarchy|None), \"Parent\" (\:968e\:5c64\:5316\:3067\:89aa\:5019\:88dc\:306b\:306a\:308b\:5074: From|To|Either|None), \"Affinity\" (\:89aa\:5b50\:89aa\:548c\:5ea6\:306e\:4fc2\:6570)|>|>\:3002";
$SourceVaultKGNodeKinds::usage = "$SourceVaultKGNodeKinds \:306f\:30ce\:30fc\:30c9\:7a2e\:5225\:306e\:4e00\:89a7 (Claim / Concept / Definition / Method / Experiment / Result / Equation / Figure / Question / Conclusion / Background / Section / Survey)\:3002";
$SourceVaultKGAudiencePresets::usage = "$SourceVaultKGAudiencePresets \:306f\:8074\:304d\:624b\:30d7\:30ea\:30bb\:30c3\:30c8 (\"\:9ad8\:6821\:751f\" / \"\:5927\:5b66\:7406\:7cfb\:5b66\:90e8\:5352\" / \"IT\:30a8\:30f3\:30b8\:30cb\:30a2\" / \"\:9ad8\:6821\:6570\:5b66III\" \:306a\:3069) -> <|\"Level\", \"Knowledge\" -> <|\:9818\:57df -> \:7406\:89e3\:5ea6|>|> \:306e\:8868\:3002SourceVaultKGAudience \:304c\:53c2\:7167\:3059\:308b\:3002";
$SourceVaultKGDomainAliases::usage = "$SourceVaultKGDomainAliases \:306f\:9818\:57df\:540d\:306e\:5225\:540d\:8868 (\:82f1\:8a9e\:540d -> \:6b63\:6e96\:65e5\:672c\:8a9e\:540d)\:3002\:30ce\:30fc\:30c9\:306e Domains \:3068\:8074\:304d\:624b\:306e Knowledge \:306e\:7167\:5408\:306b\:4f7f\:3046\:3002";
$SourceVaultKGViewMaxRows::usage = "$SourceVaultKGViewMaxRows \:306f View \:95a2\:6570\:304c Dataset \:306b\:51fa\:3059\:6700\:5927\:884c\:6570 (\:65e2\:5b9a 200)\:3002";
$SourceVaultKGTooHard::usage = "$SourceVaultKGTooHard \:306f\:300c\:8074\:304d\:624b\:306b\:3068\:3063\:3066\:96e3\:3057\:3059\:304e\:308b\:300d\:3068\:5224\:5b9a\:3059\:308b need (\:96e3\:6613\:5ea6 - \:65e2\:77e5\:5ea6) \:306e\:95be\:5024 (\:65e2\:5b9a 0.6)\:3002\:8d85\:3048\:305f\:30ce\:30fc\:30c9\:306f score \:3092\:534a\:6e1b\:3057 TooHard \:30d5\:30e9\:30b0\:3092\:4ed8\:3051\:308b\:3002";

SourceVaultKGRoot::usage = "SourceVaultKGRoot[] \:306f\:77e5\:8b58\:30b0\:30e9\:30d5\:5c64\:306e\:4fdd\:5b58\:30c7\:30a3\:30ec\:30af\:30c8\:30ea\:3092\:8fd4\:3059 (\:7121\:3051\:308c\:3070\:4f5c\:308b)\:3002";
SourceVaultKGNew::usage = "SourceVaultKGNew[graphId, opts] \:306f\:7a7a\:306e\:77e5\:8b58\:30b0\:30e9\:30d5\:9023\:60f3\:3092\:8fd4\:3059\:3002opts: \"Title\" / \"Language\" (\:65e2\:5b9a \"ja\") / \"Sources\" ({<|\"Key\",\"Locator\",\"Kind\",\"Note\"|>..}) / \"Kind\" (Paper|Survey|Background) / \"PrivacyLevel\"\:3002";
SourceVaultKGValidate::usage = "SourceVaultKGValidate[kg] \:306f\:30ce\:30fc\:30c9\:30fb\:8fba\:3092\:6b63\:898f\:5316\:3057 (\:65e2\:5b9a\:5024\:88dc\:5b8c\:30fb\:672a\:77e5\:306e\:8fba\:7a2e\:5225\:3092 RelatedTo \:306b\:4e38\:3081\:308b\:30fb\:7aef\:70b9\:306e\:7121\:3044\:8fba\:3084\:81ea\:5df1\:30eb\:30fc\:30d7\:3092\:843d\:3068\:3059\:30fbRoot \:3092\:6c7a\:3081\:308b)\:3001\"Warnings\" \:3092\:4ed8\:3051\:305f KG \:3092\:8fd4\:3059\:3002\:3059\:3079\:3066\:306e\:53d6\:308a\:8fbc\:307f\:53e3\:304c\:3053\:308c\:3092\:901a\:308b\:3002";
SourceVaultKGFromJSON::usage = "SourceVaultKGFromJSON[json] \:306f LLM \:5fdc\:7b54 (```json \:30d5\:30a7\:30f3\:30b9\:4ed8\:304d\:53ef) \:3084 JSON \:6587\:5b57\:5217 / \:9023\:60f3\:3092 KG \:306b\:5909\:63db\:3057\:3066 SourceVaultKGValidate \:3092\:901a\:3059\:3002\:5931\:6557\:306f Failure\:3002";
SourceVaultKGToJSON::usage = "SourceVaultKGToJSON[kg] \:306f KG \:3092 JSON \:6587\:5b57\:5217\:306b\:3059\:308b\:3002";
SourceVaultKGMerge::usage = "SourceVaultKGMerge[kg, delta, opts] \:306f\:5dee\:5206 KG (\:30ce\:30fc\:30c9/\:8fba\:306e\:8ffd\:52a0\:30fb\:4e0a\:66f8\:304d) \:3092\:53d6\:308a\:8fbc\:3080\:3002\:540c\:3058 Id \:306e\:30ce\:30fc\:30c9\:306f delta \:306e\:30ad\:30fc\:3060\:3051\:4e0a\:66f8\:304d\:3001\:8fba\:306f (From, To, EdgeKind) \:3067\:91cd\:8907\:6392\:9664\:3002\"Language\"->\"en\" \:3092\:4e0e\:3048\:308b\:3068 delta \:306e\:6587\:5b57\:5217\:30c6\:30ad\:30b9\:30c8 (Label/Summary/Points/Talk) \:306f\:305d\:306e\:8a00\:8a9e\:306e\:8a33\:3068\:3057\:3066\:65e2\:5b58\:30c6\:30ad\:30b9\:30c8\:306b\:4f75\:8a18\:3055\:308c\:308b\:3002";
SourceVaultKGNode::usage = "SourceVaultKGNode[kg, id] \:306f\:30ce\:30fc\:30c9\:9023\:60f3 (\:7121\:3051\:308c\:3070 Missing)\:3002";
SourceVaultKGText::usage = "SourceVaultKGText[node, key, lang] \:306f\:8a00\:8a9e\:5225\:30c6\:30ad\:30b9\:30c8 (\"Label\"/\"Summary\"/\"Talk\"/\"Cite\" \:306f String\:3001\"Points\" \:306f List) \:3092\:8fd4\:3059\:3002lang \:304c\:7121\:3051\:308c\:3070\:4e3b\:8a00\:8a9e \[RightArrow] \:4efb\:610f\:306e\:8a00\:8a9e\:306e\:9806\:3067\:843d\:3061\:308b\:3002";
SourceVaultKGSave::usage = "SourceVaultKGSave[kg] \:306f KG \:3092 <root>/graphs/<graphId>.json \:306b\:4fdd\:5b58\:3059\:308b (\:524d\:7248\:306f graphs/history/ \:306b\:9000\:907f)\:3002";
SourceVaultKGLoad::usage = "SourceVaultKGLoad[graphId] \:306f\:4fdd\:5b58\:6e08\:307f KG \:3092\:8aad\:3080 (\:7121\:3051\:308c\:3070 Missing)\:3002";
SourceVaultKGRepairMojibake::usage = "SourceVaultKGRepairMojibake[] \:306f\:4fdd\:5b58\:6e08\:307f\:306e KG (graphs/) \:3068\:5468\:8fba\:77e5\:8b58\:306e\:66f8\:5eab (background/) \:306e\:6587\:5b57\:5316\:3051 (UTF-8 \:306e\:30d0\:30a4\:30c8\:3092 1 \:6587\:5b57\:305a\:3064\:8aad\:3093\:3060\:5f62\:3002gaw\[EAcute] \[RightArrow] gaw\[CapitalATilde]\[Copyright] \:306a\:3069) \:3092\:76f4\:3057\:3066\:66f8\:304d\:623b\:3059\:3002<|\"Checked\", \"Fixed\", \"Files\"|> \:3092\:8fd4\:3059\:3002\:53d6\:308a\:8fbc\:307f (SourceVaultKGFromJSON / SourceVaultKGMerge) \:306f\:5165\:53e3\:3067\:540c\:3058\:4fee\:5fa9\:3092\:3059\:308b\:3002";
SourceVaultKGList::usage = "SourceVaultKGList[] \:306f\:4fdd\:5b58\:6e08\:307f KG \:306e\:4e00\:89a7 ({<|\"GraphId\",\"Title\",\"Kind\",\"NodeCount\",\"EdgeCount\",\"UpdatedAtUTC\"|>..})\:3002";
SourceVaultKGDelete::usage = "SourceVaultKGDelete[graphId] \:306f\:4fdd\:5b58\:6e08\:307f KG \:3092\:524a\:9664\:3059\:308b (history \:306f\:6b8b\:3059)\:3002";

SourceVaultKGAudience::usage = "SourceVaultKGAudience[spec] \:306f\:8074\:304d\:624b\:6307\:5b9a\:3092\:6b63\:898f\:5316\:3059\:308b\:3002spec: \:30d7\:30ea\:30bb\:30c3\:30c8\:540d (\"\:5927\:5b66\:7406\:7cfb\:5b66\:90e8\:5352\") / \:30ab\:30f3\:30de\:533a\:5207\:308a (\"\:9ad8\:6821\:751f, \:96fb\:6c17\:5316\:5b66=0.3, \:9ad8\:6821\:6570\:5b66III\") / \:30ea\:30b9\:30c8 / <|\"Level\", \"Knowledge\", \"Presets\", \"Language\", \"Description\"|>\:3002\:7d50\:679c\:306f <|\"Level\" (\:4e3b\:984c\:306e\:7406\:89e3\:5ea6 0-1), \"Knowledge\" -> <|\:9818\:57df -> \:7406\:89e3\:5ea6|>, \"Presets\", \"Language\", \"Description\", \"Unknown\" (\:89e3\:91c8\:3067\:304d\:306a\:304b\:3063\:305f\:8a9e)|>\:3002";
SourceVaultKGNeed::usage = "SourceVaultKGNeed[kg, audience] \:306f\:5404\:30ce\:30fc\:30c9\:306e need = \:96e3\:6613\:5ea6 - \:8074\:304d\:624b\:306e\:65e2\:77e5\:5ea6 (<|id -> Real|>)\:30020 \:4ee5\:4e0b\:306a\:3089\:65e2\:77e5\:3068\:3057\:3066\:6271\:3048\:308b\:3002";
SourceVaultKGScores::usage = "SourceVaultKGScores[kg, audience] \:306f\:5404\:30ce\:30fc\:30c9\:306e <|\"Need\", \"Known\", \"Score\" (\:91cd\:8981\:5ea6 x \:8074\:304d\:624b\:306b\:3068\:3063\:3066\:306e\:5fc5\:8981\:5ea6), \"Flags\" (TooHard / Assumed)|>\:3002";

SourceVaultKGOrderGraph::usage = "SourceVaultKGOrderGraph[kg] \:306f\:9806\:5e8f\:5236\:7d04\:8fba (Order->True \:306e\:7a2e\:5225 + Contains) \:3060\:3051\:306e\:6709\:5411 Graph \:3068\:3001\:5faa\:74b0\:3092\:5207\:308b\:305f\:3081\:306b\:843d\:3068\:3057\:305f\:8fba\:306e\:4e00\:89a7\:3092 <|\"Graph\", \"Dropped\"|> \:3067\:8fd4\:3059\:3002";
SourceVaultKGLinearOrder::usage = "SourceVaultKGLinearOrder[kg, strategy] \:306f\:9806\:5e8f\:5236\:7d04\:3092\:6e80\:305f\:3059\:7dda\:5f62\:62e1\:5f35 (\:30c8\:30dd\:30ed\:30b8\:30ab\:30eb\:9806) \:3092\:8fd4\:3059\:3002strategy: \"Source\" (\:8ad6\:6587\:306e\:51fa\:73fe\:9806\:512a\:5148) / \"Importance\" / \"Difficulty\" (\:6613\[RightArrow]\:96e3) / \"Coherent\" (\:76f4\:524d\:30ce\:30fc\:30c9\:3068\:306e\:95a2\:9023\:5ea6\:512a\:5148)\:3002";
SourceVaultKGOrderedTree::usage = "SourceVaultKGOrderedTree[kg, opts] \:306f\:6700\:5c0f\:5168\:57df\:9806\:5e8f\:6728 (\:7dda\:5f62\:62e1\:5f35\:306e\:968e\:5c64\:5206\:5272) \:3092\:8fd4\:3059\:3002<|\"Root\", \"Order\" (\:524d\:9806\:8d70\:67fb = \:7dda\:5f62\:62e1\:5f35), \"Parent\", \"Children\", \"Depth\", \"Score\", \"Strategy\", \"Diagnostics\"|>\:3002opts: \"Strategy\" (\:65e2\:5b9a \"Source\") / \"MaxDepth\" (\:65e2\:5b9a 3) / \"DepthPenalty\" (\:65e2\:5b9a 0.02)\:3002";
SourceVaultKGOrderedTrees::usage = "SourceVaultKGOrderedTrees[kg, opts] \:306f\:8907\:6570\:6226\:7565\:3067\:9806\:5e8f\:6728\:5019\:88dc\:3092\:4f5c\:308a Score \:964d\:9806\:3067\:8fd4\:3059\:3002\"Strategies\"->{...}\:3002";
SourceVaultKGOverDegree::usage = "SourceVaultKGOverDegree[kg, d, opts] \:306f\:9806\:5e8f\:6728\:3067\:5b50 (\:96a0\:3059\:30fb\:975e\:516c\:958b\:3092\:9664\:304f) \:304c d \:500b\:3092\:8d85\:3048\:308b\:30ce\:30fc\:30c9\:306e\:4e00\:89a7 <|\"Node\", \"Children\", \"Degree\", \"Depth\"|>\:3002opts: \"Tree\" (\:8a08\:7b97\:6e08\:307f\:306e\:9806\:5e8f\:6728) / \"Strategy\"\:3002";
SourceVaultKGBalance::usage = "SourceVaultKGBalance[kg, opts] \:306f\:9806\:5e8f\:6728\:306e\:3069\:306e\:30ce\:30fc\:30c9\:3082\:5b50\:304c \"MaxDegree\" (\:65e2\:5b9a 5) \:500b\:4ee5\:4e0b\:306b\:306a\:308b\:3088\:3046\:3001\:8d85\:3048\:308b\:30ce\:30fc\:30c9\:306e\:5b50\:3092\:6728\:306e\:9806\:306e\:307e\:307e\:9023\:7d9a\:3057\:305f\:300c\:307e\:3068\:307e\:308a\:300d(Section\:3001\"Cluster\" -> True\:3001Id grp_<\:89aa>_<n>) \:306b\:5206\:3051\:3066\:6bb5\:3092\:8db3\:3059 (\:6df1\:3044\:65b9\:304b\:3089\:3001\:5168\:90e8\:304c\:4e0a\:9650\:4ee5\:4e0b\:306b\:306a\:308b\:307e\:3067\:3002\:5b50\:304c\:4e0a\:9650\:306e 2 \:4e57\:3092\:8d85\:3048\:308b\:3068\:304d\:306f 2 \:6bb5\:4ee5\:4e0a)\:3002\"Groups\" -> <|\:89aa -> {{\:5b50 Id..}..}|> \:3068 \"Info\" -> <|\:89aa -> {<|\"Label\", \"Gist\", \"Summary\"|>..}|> \:3067\:5206\:3051\:65b9\:3068\:984c\:76ee\:30fb\:4e00\:884c\:8981\:7d04\:3092\:4e0e\:3048\:3089\:308c\:308b (\:9806\:3067\:9023\:7d9a\:30fb\:6f0f\:308c\:306a\:304f\:30fb\:5404\:307e\:3068\:307e\:308a\:304c\:4e0a\:9650\:4ee5\:4e0b\:3067\:306a\:3051\:308c\:3070\:6368\:3066\:3066\:7b49\:5206\:3057 \"Rejected\" \:306b\:8a18\:9332)\:3002\:623b\:308a <|\"KG\", \"Added\", \"Rejected\", \"Unresolved\", \"Rounds\", \"MaxDegree\"|>\:3002\:4fdd\:5b58\:306f\:3057\:306a\:3044\:3002\:9806\:5e8f\:6728\:306e\:6df1\:3055\:306e\:4e0a\:9650 (\"MaxDepth\" -> Automatic) \:306f\:307e\:3068\:307e\:308a\:306e\:6bb5\:306e\:5206\:3060\:3051\:6df1\:304f\:306a\:308b\:3002\:76ee\:6b21 (\:5168\:4f53\:306e\:6d41\:308c) \:306f\:90e8\:306e\:4e00\:884c\:8981\:7d04 \"Gist\" \:3092\:4e26\:3079\:308b\:3002";
SourceVaultKGTocQ::usage = "SourceVaultKGTocQ[kg] \:306f\:77e5\:8b58\:30b0\:30e9\:30d5\:306b\:76ee\:6b21 (kg[\"Toc\"]) \:304c\:3042\:308b\:304b (v1.46)\:3002";
SourceVaultKGTocTree::usage = "SourceVaultKGTocTree[kg] \:306f\:76ee\:6b21\:306e\:6728\:3092\:9806\:5e8f\:6728\:3068\:540c\:3058\:5f62 (Root / Order (\:524d\:9806) / Parent / Children / Depth\:3001Strategy \"Toc\") \:3067\:8fd4\:3059\:3002\:76ee\:6b21\:3092\:4f5c\:3063\:305f\:3042\:3068\:306b\:8db3\:3055\:308c\:305f\:30ce\:30fc\:30c9\:306f\:3001\:524d\:306e\:679a (Precedes \:306e\:5143) \:306e\:5f8c\:308d \:2192 Contains \:306e\:89aa\:306e\:672b\:5c3e \:2192 \:524d\:63d0\:5148\:306e\:524d \:2192 \:6839\:306e\:672b\:5c3e \:306b\:7f6e\:304f\:3002SourceVaultKGOrderedTree \:3082\:76ee\:6b21\:304c\:3042\:308c\:3070\:3053\:308c\:3092\:8fd4\:3059 (\"UseToc\" -> False \:3067\:8cc7\:6599\:306e\:6728)\:3002";
SourceVaultKGTocMove::usage = "SourceVaultKGTocMove[kg, id, after] \:306f\:76ee\:6b21\:306e\:4e2d\:3067 id \:3092 after \:306e\:76f4\:5f8c\:3078\:52d5\:304b\:3059 (\:8abf\:6574\:306e After)\:3002\:4f7f\:308f\:306a\:3044\:3068\:6c7a\:3081\:305f\:9805\:76ee\:306a\:3089\:76ee\:6b21\:306b\:623b\:3059\:3002after \:304c\:76ee\:6b21\:306b\:7121\:3044\:3001\:307e\:305f\:306f id \:306e\:90e8\:5206\:6728\:306e\:4e2d\:306a\:3089 kg \:3092\:305d\:306e\:307e\:307e\:8fd4\:3059\:3002";
SourceVaultKGImportNodes::usage = "SourceVaultKGImportNodes[kg, from, ids | All, opts] \:306f\:5225\:306e KG (from) \:306e\:30ce\:30fc\:30c9\:3092 kg \:306b\:53d6\:308a\:8fbc\:3080 (v1.47\:3002\:8a08\:7b97\:30ce\:30fc\:30c8\:306e\:5358\:4f4d\:306e\:518d\:5229\:7528\:306a\:3069)\:3002ids \:3068\:305d\:306e Contains \:306e\:5b50\:5b6b\:3092\:65b0\:3057\:3044 Id (\"Prefix\" \:65e2\:5b9a = from \:306e GraphId \:304b\:3089) \:3067\:5199\:3057\:3001\:4e2d\:306e\:8fba\:3082\:5199\:3059\:3002\:3044\:3061\:3070\:3093\:4e0a\:306e\:30ce\:30fc\:30c9\:306f \"Parent\" (\:65e2\:5b9a \:6839) \:306e\:5b50\:3001\"After\" \:304c\:3042\:308c\:3070\:305d\:306e\:5f8c\:308d\:3002\:5143\:306f \"Origin\" -> <|Graph, Id|>\:3002\:30ce\:30fc\:30c9\:306e \"Links\" (\"<GraphId>#<Id>\") \:304c kg \:306e\:30ce\:30fc\:30c9\:3092\:6307\:3057\:3066\:3044\:308c\:3070 Supports \:306e\:8fba (\"Link\" -> False \:3067\:6b62\:3081\:308b)\:3002\"Pin\" -> True \:3067\:3044\:3061\:3070\:3093\:4e0a\:306e\:30ce\:30fc\:30c9\:306b\:5fc5\:305a\:51fa\:3059\:5370\:3002\:623b\:308a <|\"KG\", \"Added\", \"Map\", \"Linked\"|> (\:4fdd\:5b58\:306f\:3057\:306a\:3044)\:3002";
SourceVaultKGSetToc::usage = "SourceVaultKGSetToc[kg, <|\:89aa -> {\:5b50..}|>, opts] \:306f\:76ee\:6b21\:3092 KG \:306b\:66f8\:304f (\:4fdd\:5b58\:306f\:3057\:306a\:3044)\:3002\"Groups\" = \:76ee\:6b21\:306e\:7bc0\:30ce\:30fc\:30c9 {<|\"Id\", \"Label\", \"Gist\", \"Summary\", \"Importance\", \"Include\" (Must|Optional)|>..} (\:65e2\:5b58\:306e Id \:306a\:3089\:4e00\:884c\:8981\:7d04\:306a\:3069\:3092\:66f8\:304d\:8db3\:3059)\:3001\"Omitted\" = \:4f7f\:308f\:306a\:3044\:8449\:3001\"MaxDegree\" (\:65e2\:5b9a 5) \:3092\:8d85\:3048\:308b\:5b50\:306e\:5217\:306f\:9023\:7d9a\:3057\:305f\:584a\:306b\:5206\:3051\:3001\:5144\:5f1f\:3092\:4f9d\:5b58 (Prerequisite / Derives) \:3067\:4e26\:3079\:66ff\:3048\:308b (\:5b89\:5b9a\:306a\:4f4d\:76f8\:6574\:5217\:3001\:9589\:8def\:306f \"Violations\")\:3002\:6a5f\:68b0\:7684\:306a\:307e\:3068\:307e\:308a (Cluster) \:306f\:5916\:3057\:3066\:5b50\:3092\:5143\:306e\:89aa\:306b\:623b\:3059 (\"DropClusters\")\:3002\:623b\:308a <|\"KG\", \"Added\", \"Split\", \"Violations\"|>\:3002";
SourceVaultKGMechanicalToc::usage = "SourceVaultKGMechanicalToc[kg, opts] \:306f LLM \:3092\:4f7f\:308f\:306a\:3044\:76ee\:6b21: \:8cc7\:6599\:306e\:69cb\:9020 (\:9806\:5e8f\:6728) \:3092\:305d\:306e\:307e\:307e\:76ee\:6b21\:306b\:3057\:3001\:6b21\:6570\:306e\:4e0a\:9650\:306f SourceVaultKGBalance \:306e\:307e\:3068\:307e\:308a\:3067\:5b88\:308b\:3002\:623b\:308a\:306f SourceVaultKGSetToc \:3068\:540c\:3058\:306b \"Preview\" (\:8db3\:3057\:305f\:307e\:3068\:307e\:308a) \:3092\:52a0\:3048\:305f\:3082\:306e\:3002";
SourceVaultKGTocPlan::usage = "SourceVaultKGTocPlan[kg, tree, opts] \:306f\:76ee\:6b21\:304b\:3089\:306e\:8a08\:753b (v1.46)\:3002\:76ee\:6b21\:306e\:6728\:3092\:4e0a\:304b\:3089\:958b\:304f: \:3069\:306e\:7bc0\:3082\:6982\:8981\:306e 1 \:679a\:304b\:3001\:958b\:3044\:3066\:5b50\:3092\:305d\:308c\:305e\:308c\:679a\:306b\:3059\:308b\:304b\:3002\:958b\:304f\:306e\:306f\:6d45\:3044\:7bc0\:304b\:3089\:3001\:540c\:3058\:6df1\:3055\:306a\:3089\:91cd\:8981\:5ea6 (Include Must \:306f +1) \:306e\:9ad8\:3044\:9806\:306b\:3001\:679a\:6570 (\"Slides\" / \"Seconds\") \:306b\:53ce\:307e\:308b\:3068\:3053\:308d\:307e\:3067\:3002\:958b\:3044\:305f\:7bc0\:306e\:9053\:6a19\:306e\:679a\:306f\:6839\:3068\:6df1\:3055 \"RoadmapDepth\" (\:65e2\:5b9a 1 = \:90e8) \:307e\:3067\:3001\:305d\:308c\:3088\:308a\:6df1\:3044\:7bc0\:306f\:958b\:304f\:3068\:81ea\:5206\:306e\:679a\:3092\:5b50\:306b\:8b72\:308b (\"Headings\")\:3002\:53ce\:307e\:3089\:306a\:3044\:7bc0\:306f\:6982\:8981\:306e 1 \:679a\:3092\:6b8b\:3057\:3066\:5927\:4e8b\:306a\:5b50\:3060\:3051\:679a\:306b\:3059\:308b (\"Partial\")\:30021 \:679a\:306a\:3089\:6839\:3060\:3051 (\:90e8\:306e\:4e00\:884c\:8981\:7d04\:3092\:4e26\:3079\:308b)\:3002\:5fc5\:305a\:51fa\:3059 (Pinned) \:306f\:7956\:5148\:3092\:958b\:304b\:306a\:304f\:3066\:3082\:524d\:9806\:306e\:4f4d\:7f6e\:306b\:679a\:3068\:3057\:3066\:5165\:308b\:3002\:96a0\:3059\:30fb\:975e\:516c\:958b\:30fbInclude Omit\:30fb\:8074\:304d\:624b\:304c\:77e5\:3063\:3066\:3044\:308b\:5468\:8fba\:77e5\:8b58\:306f\:5916\:3059\:3002\:623b\:308a\:306f SourceVaultKGPlan \:3068\:540c\:3058\:5f62\:306b \"Mode\" -> \"Toc\"\:3001\:5404\:679a\:306e \"AllChildren\" / \"Expanded\" / \"Figure\"\:3001\"TreeParent\" / \"TreeInternal\" \:3092\:52a0\:3048\:305f\:3082\:306e (SourceVaultKGOutline \:306f\:76ee\:6b21\:306e\:7ae0\:7acb\:3066\:3067\:7d44\:3080)\:3002";
SourceVaultKGLevelSummaries::usage = "SourceVaultKGLevelSummaries[kg, tree, opts] \:306f\:6728\:306e\:5185\:90e8\:30ce\:30fc\:30c9\:3054\:3068\:306b\:6982\:8981 (\:81ea\:8eab\:306e Summary + \:5b50\:30e9\:30d9\:30eb) \:3092 <|id -> <|\"Depth\", \"Label\", \"Summary\", \"Children\"|>|> \:3067\:8fd4\:3059 (\:6c7a\:5b9a\:7684)\:3002LLM \:3067\:78e8\:304f\:306b\:306f SourceVaultKGSummaryPrompt\:3002";
SourceVaultKGVerify::usage = "SourceVaultKGVerify[kg, tree] \:306f\:9806\:5e8f\:6728\:306e\:7834\:7dbb\:691c\:8a3c: <|\"Status\" (OK|Warnings|Broken), \"OrderViolations\", \"Cycles\" (\:843d\:3068\:3057\:305f\:8fba), \"Orphans\", \"RootMismatch\", \"MissingPrerequisites\"|>\:3002";

SourceVaultKGPlan::usage = "SourceVaultKGPlan[kg, tree, opts] \:306f\:679a\:6570/\:6642\:9593\:3068\:8074\:304d\:624b\:304b\:3089\:30b9\:30e9\:30a4\:30c9\:8a08\:753b\:3092\:4f5c\:308b\:3002opts: \"Slides\" (\:679a\:6570 | Automatic) / \"Seconds\" (\:7dcf\:79d2\:6570) / \"SecondsPerSlide\" (\:65e2\:5b9a 25) / \"Audience\" / \"MaxPackedPerSlide\" (\:65e2\:5b9a 4) / \"PackRatio\" (\:65e2\:5b9a 0.35) / \"ReleaseCeiling\" (\:65e2\:5b9a 0.5) / \"ForceParts\" (\:65e2\:5b9a 0.5: root \:76f4\:4e0b\:306e\:90e8\:3092\:5fc5\:305a 1 \:679a\:306b\:3059\:308b Importance \:306e\:4e0b\:9650\:3002None \:3067\:5168\:90e8)\:3002\:7d50\:679c <|\"Slides\" -> {<|\"NodeId\", \"Packed\", \"Seconds\", \"Flags\"|>..}, \"Pruned\", \"Assumed\", \"Promoted\", \"Threshold\", \"Scores\", \"Diagnostics\"|>\:3002 v1.42: \:30ce\:30fc\:30c9\:306e \"Pinned\" -> True \:306f\:300c\:5fc5\:305a\:51fa\:3059\:300d\:5370\:3067\:3001\:70b9\:6570\:30fb\:524d\:63d0\:77e5\:8b58\:306e\:5224\:5b9a\:306b\:3088\:3089\:305a\:90e8\:3068\:540c\:3058\:304f\:5148\:306b 1 \:679a\:3092\:53d6\:308b (\:67a0\:3092\:8d85\:3048\:3066\:3082\:51fa\:3059\:3002\:96a0\:3059\:30fb\:975e\:516c\:958b\:306f\:9664\:304f)\:3002\:7d50\:679c\:306e \"Pinned\" \:3068\:5404\:679a\:306e Flags \:306b\:51fa\:308b\:3002";
SourceVaultKGVerifyPlan::usage = "SourceVaultKGVerifyPlan[kg, plan] \:306f\:8a08\:753b\:306e\:63d0\:793a\:9806\:3067\:9806\:5e8f\:5236\:7d04\:304c\:5b88\:3089\:308c\:3066\:3044\:308b\:304b\:3092\:691c\:8a3c\:3059\:308b (<|\"Status\", \"Violations\"|>)\:3002";
SourceVaultKGOutline::usage = "SourceVaultKGOutline[kg, plan, opts] \:306f\:8a08\:753b\:3092\:8a00\:8a9e\:5225\:306e\:30a2\:30a6\:30c8\:30e9\:30a4\:30f3 (1 \:679a = <|NodeId, Title, Points, Sub, Assets, Cite, Talk, Seconds, Flags, Depth, Kind, Crumb, Continuation|>) \:306b\:3059\:308b\:3002opts: \"Language\" / \"MaxAssetsPerSlide\" (2) / \"MaxPointsPerSlide\" (6) / \"MaxLinesPerSlide\" (8\:3001\:6298\:308a\:8fd4\:3057\:306f \"CharsPerLine\" 40 \:3067\:6570\:3048\:308b\:3001\:56f3\:306f \"FigureLines\" 4 \:884c\:5206) / \"Agenda\" (Automatic: \:90e8\:304c 3 \:3064\:4ee5\:4e0a\:306a\:3089\:6839\:306e\:76f4\:5f8c\:306b\:300c\:5168\:4f53\:306e\:6d41\:308c\:300d\:3092 1 \:679a) / \"Roadmap\" (True: \:7bc0\:30b9\:30e9\:30a4\:30c9\:306e\:8981\:70b9\:3092\:305d\:306e\:7bc0\:306e\:5b50\:30b9\:30e9\:30a4\:30c9\:306e\:984c\:76ee\:306b\:3059\:308b) / \"Crumbs\" (True: \:5404\:679a\:306b\:300c\:7b2ck\:90e8 \[Ellipsis] \:203a \:89aa\:300d\:306e\:30d1\:30f3\:304f\:305a)\:3002\:53ce\:307e\:3089\:306a\:3044\:5b50\:306f\:540c\:3058\:984c\:76ee + (\:7d9a\:304d) \:306e\:30b9\:30e9\:30a4\:30c9\:3078\:3002\:539f\:7a3f\:306f\:7b87\:6761\:66f8\:304d\:3068\:540c\:3058\:9806 (\:30ce\:30fc\:30c9\:306e Talk \:3092\:8868\:793a\:3057\:305f\:8981\:70b9\:6570\:306b\:5207\:308a\:8a70\:3081\:3001\:7121\:3051\:308c\:3070\:8981\:70b9\:3092\:305d\:306e\:307e\:307e\:6587\:306b)\:3002\:7d50\:679c\:306b \"Parts\" \:3068 \"Agenda\"\:3002";
SourceVaultKGOutlineToMarkdown::usage = "SourceVaultKGOutlineToMarkdown[outline] \:306f SlideWorkflow \:306e\:30b7\:30ca\:30ea\:30aa Markdown \:3068\:3001<<FIGn>> \:306b\:5bfe\:5fdc\:3059\:308b\:8cc7\:7523\:6307\:5b9a\:30ea\:30b9\:30c8\:3092 <|\"Markdown\", \"Assets\"|> \:3067\:8fd4\:3059 (\:8cc7\:7523\:306e\:5b9f\:4f53\:5316\:306f SlideWorkflow \:5074)\:3002 v1.42: \:30ce\:30fc\:30c9\:306e \"FigureLayout\" -> \"Row\" \:306e\:679a\:306f\:56f3\:3092 4 \:3064\:307e\:3067\:8f09\:305b\:30011 \:884c\:306b <<FIG1>> <<FIG2>> \:3068\:4e26\:3079\:308b (SlideWorkflow \:304c\:9ad8\:3055\:3092\:305d\:308d\:3048\:3066\:6a2a\:306b\:4e26\:3079\:308b)\:3002";

SourceVaultKGCompose::usage = "SourceVaultKGCompose[{kg1, kg2, ..}, opts] \:306f\:8907\:6570 KG \:3092 1 \:3064\:306e\:30b5\:30fc\:30d9\:30a4 KG \:306b\:5408\:6210\:3059\:308b (\:30ce\:30fc\:30c9 Id \:306f <graphId>/<id> \:306b\:3001bg: \:306e\:5468\:8fba\:77e5\:8b58\:30ce\:30fc\:30c9\:306f\:5171\:6709\:30fb\:7d71\:5408\:3001\:5171\:6709\:30ce\:30fc\:30c9\:3092\:4ecb\:3057\:305f\:8ad6\:6587\:9593 RelatedTo \:3092\:4ed8\:4e0e)\:3002opts: \"GraphId\" / \"Title\" / \"Language\" / \"Chronological\" (Year \:3067 Precedes \:3092\:4ed8\:3051\:308b) / \"Edges\" (\:8ffd\:52a0\:8fba)\:3002";

SourceVaultKGBackgroundLink::usage = "SourceVaultKGBackgroundLink[kg] \:306f Layer Background \:306e\:30ce\:30fc\:30c9\:3092\:5171\:6709 background \:5c64 (<root>/background/bg-<slug>.json) \:3068\:7167\:5408\:3057\:3001\:65e2\:5b58\:306a\:3089 BackgroundRef \:3092\:5f35\:308a\:3001\:7121\:3051\:308c\:3070\:65b0\:898f\:767b\:9332\:3059\:308b\:3002<|\"Graph\", \"Linked\", \"Created\"|>\:3002";
SourceVaultKGBackgroundSearch::usage = "SourceVaultKGBackgroundSearch[text, opts] \:306f\:5171\:6709 background \:30ce\:30fc\:30c9\:3092\:30e9\:30d9\:30eb/\:5225\:540d\:306e bigram \:985e\:4f3c\:3067\:691c\:7d22\:3059\:308b ({<|\"Id\",\"Label\",\"Score\",\"Graphs\"|>..})\:3002";
SourceVaultKGBackgroundList::usage = "SourceVaultKGBackgroundList[] \:306f\:5171\:6709 background \:30ce\:30fc\:30c9\:306e\:4e00\:89a7\:3002";
SourceVaultKGSuggestPastSlides::usage = "SourceVaultKGSuggestPastSlides[kg, kbId] \:306f SourceVault_kb (Graph-RAG) \:304c\:30ed\:30fc\:30c9\:6e08\:307f\:306a\:3089\:3001\:5468\:8fba\:77e5\:8b58\:30ce\:30fc\:30c9\:3054\:3068\:306b\:904e\:53bb\:30c7\:30c3\:30ad\:306e\:30b9\:30e9\:30a4\:30c9\:3092\:691c\:7d22\:3057\:3066\:5f15\:7528\:5019\:88dc ({<|\"NodeId\",\"Label\",\"Deck\",\"Slide\",\"Title\",\"Score\"|>..}) \:3092\:8fd4\:3059\:3002KB \:304c\:7121\:3051\:308c\:3070 {}\:3002";

SourceVaultKGExtractionPrompt::usage = "SourceVaultKGExtractionPrompt[sourceText, opts] \:306f\:8ad6\:6587\:672c\:6587\:304b\:3089 KG JSON \:3092\:62bd\:51fa\:3055\:305b\:308b\:30d7\:30ed\:30f3\:30d7\:30c8 (\:7d14\:95a2\:6570)\:3002opts: \"GraphId\" / \"Title\" / \"Language\" / \"SourceKey\" / \"PDFKey\" / \"MaxNodes\"\:3002\:5fdc\:7b54\:306f SourceVaultKGFromJSON \:3067\:53d6\:308a\:8fbc\:3080\:3002";
SourceVaultKGBackgroundPrompt::usage = "SourceVaultKGBackgroundPrompt[kg, audience, opts] \:306f\:8074\:304d\:624b\:306b\:8db3\:308a\:306a\:3044\:5468\:8fba\:77e5\:8b58\:30ce\:30fc\:30c9\:3068 Prerequisite \:8fba\:3092\:5dee\:5206 JSON \:3067\:51fa\:3055\:305b\:308b\:30d7\:30ed\:30f3\:30d7\:30c8\:3002\:5fdc\:7b54\:306f SourceVaultKGMerge \:3067\:53d6\:308a\:8fbc\:3080\:3002";
SourceVaultKGSummaryPrompt::usage = "SourceVaultKGSummaryPrompt[kg, tree, opts] \:306f\:968e\:5c64\:3054\:3068\:306e\:6982\:8981\:3068\:7834\:7dbb\:306e\:6307\:6458\:3092\:51fa\:3055\:305b\:308b\:30d7\:30ed\:30f3\:30d7\:30c8\:3002";
SourceVaultKGTalkPrompt::usage = "SourceVaultKGTalkPrompt[outline, opts] \:306f\:30a2\:30a6\:30c8\:30e9\:30a4\:30f3\:306e\:5404\:679a\:306e talk \:3092\:63a5\:7d9a\:8a5e\:3064\:304d\:3067\:78e8\:304b\:305b\:308b\:30d7\:30ed\:30f3\:30d7\:30c8 (\:69cb\:6210\:30fb\:9806\:5e8f\:30fb\:30bf\:30a4\:30c8\:30eb\:306f\:5909\:3048\:306a\:3044)\:3002";
SourceVaultKGTranslatePrompt::usage = "SourceVaultKGTranslatePrompt[kg, lang, opts] \:306f\:30ce\:30fc\:30c9\:5358\:4f4d\:306e\:7ffb\:8a33 JSON \:3092\:51fa\:3055\:305b\:308b\:30d7\:30ed\:30f3\:30d7\:30c8\:3002\:5fdc\:7b54\:306f SourceVaultKGMerge[kg, delta, \"Language\"->lang]\:3002";

SourceVaultKGGraph::usage = "SourceVaultKGGraph[kg, opts] \:306f WL \:306e Graph \:3092\:8fd4\:3059 (\:9806\:5e8f\:8fba\:306f\:592a\:3044\:77e2\:5370\:3001\:7a2e\:5225\:3067\:9802\:70b9\:8272)\:3002opts: \"Order\" (\:9806\:5e8f\:8fba\:3060\:3051) / \"Labels\"\:3002";
SourceVaultKGToTopicItemGraph::usage = "SourceVaultKGToTopicItemGraph[kg] \:306f oopsseed \:306e TopicItemGraph \:5f62 (SourceVaultOOPSTopicGraphPlot \:306b\:6e21\:305b\:308b) \:306b\:6295\:5f71\:3059\:308b\:3002";
SourceVaultKGView::usage = "SourceVaultKGView[kg] \:306f\:30ce\:30fc\:30c9\:4e00\:89a7 Dataset (\:884c\:6570\:306f $SourceVaultKGViewMaxRows \:3067\:5236\:9650)\:3002";
SourceVaultKGTreeView::usage = "SourceVaultKGTreeView[kg, tree] \:306f\:9806\:5e8f\:6728\:3092\:5b57\:4e0b\:3052\:3064\:304d\:306e Dataset \:3067\:8868\:793a\:3059\:308b\:3002";
SourceVaultKGVisualize::usage = "SourceVaultKGVisualize[kg, opts] \:306f\:77e5\:8b58\:30b0\:30e9\:30d5\:306e\:56f3 (Graphics) \:3092\:8fd4\:3059 (v1.30)\:3002\"View\" -> \"Story\" (\:65e2\:5b9a: \:7bc0\:3092\:8a71\:306e\:9806\:306b\:6a2a\:3078\:3001\:7bc0\:306e\:4e2d\:8eab\:3092\:7e26\:306b\:4e26\:3079\:3001\:5468\:8fba\:77e5\:8b58\:306f\:4e0b\:306e\:5e2f) | \"Sections\" (\:7bc0\:306e\:6982\:89b3: \:7bc0\:3092\:4e00\:5217\:306b\:4e26\:3079\:3001\:7bc0\:3092\:307e\:305f\:3050\:8fba\:3092\:5f27\:3067) | \"Focus\" (\"Focus\" -> \:30ce\:30fc\:30c9 Id \:306e\:8fd1\:508d\:3001\"Radius\" -> 1..3) | \"Graph\" (\:5168\:30ce\:30fc\:30c9\:3092\:3070\:306d\:30e2\:30c7\:30eb\:3067)\:3002\:8272 = \:7a2e\:985e\:3001\:5927\:304d\:3055 = \:91cd\:8981\:5ea6\:3001\:5f62 = \:5c64 (\:672c\:6587 \:4e38 / \:5468\:8fba\:77e5\:8b58 \:56db\:89d2 / \:95a2\:9023\:7814\:7a76 \:83f1\:5f62 / \:7bc0 \:89d2\:4e38)\:3001\:8d64\:67a0 = \:672a\:63a8\:6572\:3001\:53f3\:4e0a\:306e\:70b9 = \:56f3\:30fb\:8868\:3001\:5de6\:4e0a\:306e\:70b9 = \:8cea\:7591\:5fdc\:7b54\:3001\:8584\:3044 = \:96a0\:3059\:30fb\:679d\:5208\:308a\:3002\:30ce\:30fc\:30c9\:3068\:8fba\:306b\:30c4\:30fc\:30eb\:30c1\:30c3\:30d7\:3002opts: \"EdgeKinds\" (Order / Prerequisite / Support / Related / Contains \:304b\:8fba\:306e\:7a2e\:985e\:306e\:540d\:524d)\:3001\"Layers\" (All \:304b {\"Paper\", \"Background\", \"Related\"} \:306e\:90e8\:5206)\:3001\"Labels\" (Automatic = \:7bc0\:3068\:91cd\:8981\:306a\:3082\:306e | All | None)\:3001\"Plan\" (SourceVaultKGPlan \:306e\:7d50\:679c\:3092\:91cd\:306d\:308b: \:679a\:756a\:53f7 #n\:30fb\:8a70\:3081\:8fbc\:307f\:30fb\:679d\:5208\:308a\:30fb\:65e2\:77e5)\:3001\"Selected\" (\:592a\:67a0\:306b\:3059\:308b Id)\:3001\"OnClick\" (\:30af\:30ea\:30c3\:30af\:3067 f[id] \:3092\:547c\:3076)\:3001\"Hidden\" (False \:3067\:96a0\:3057\:305f\:30ce\:30fc\:30c9\:3092\:63cf\:304b\:306a\:3044)\:3001\"Legend\" (\:65e2\:5b9a True = \:51e1\:4f8b\:3064\:304d)\:3001\"Language\"\:3002 v1.44: \"View\" -> \"Hierarchy\" (\:968e\:5c64) = \:9806\:5e8f\:6728\:3092 1 \:30ce\:30fc\:30c9 1 \:884c\:3067\:6df1\:3055\:306b\:5b57\:4e0b\:3052\:3057\:3066\:63cf\:304f (\:30b9\:30e9\:30a4\:30c9\:306f\:3053\:306e\:6728\:3092\:524d\:304b\:3089\:305f\:3069\:3063\:3066\:4f5c\:308b)\:3002\:5404\:884c\:306f\:984c\:76ee \:2014 \:4e00\:884c\:8981\:7d04 [\:5b50\:306e\:6570, \:7573\:3093\:3060\:8449\:306e\:6570]\:3001\:5b50\:304c \"MaxDegree\" (\:65e2\:5b9a 5) \:3092\:8d85\:3048\:308b\:30ce\:30fc\:30c9\:306f\:8d64\:3001\:307e\:3068\:307e\:308a (Cluster) \:306f\:5b9f\:7dda\:30fb\:4fdd\:5b58\:524d\:306e\:4e0b\:898b\:306f\:70b9\:7dda\:306e\:67a0\:3002\:4e0a\:9650\:3092\:8d85\:3048\:3066\:3044\:308c\:3070\:4fdd\:5b58\:305b\:305a\:306b\:6a5f\:68b0\:7684\:306b\:307e\:3068\:3081\:305f\:6728\:3092\:63cf\:304f (\"Balance\" -> False \:3067\:305d\:306e\:307e\:307e)\:3002\"Labels\" -> All \:3067\:8449\:3082\:51fa\:3059\:3002\"Strategy\" \:306f\:9806\:5e8f\:6728\:306e\:65b9\:91dd\:3002";
SourceVaultKGLegend::usage = "SourceVaultKGLegend[lang] \:306f SourceVaultKGVisualize \:306e\:51e1\:4f8b (\:7a2e\:985e\:306e\:8272\:3068\:5f62\:30fb\:8fba\:306e\:7a2e\:985e\:30fb\:5370)\:3002";
SourceVaultKGPlanView::usage = "SourceVaultKGPlanView[kg, plan] \:306f\:30b9\:30e9\:30a4\:30c9\:8a08\:753b\:306e Dataset (\:756a\:53f7 / \:30bf\:30a4\:30c8\:30eb / \:8a70\:3081\:8fbc\:307f / \:79d2 / \:30d5\:30e9\:30b0)\:3002";

Begin["`KGPrivate`"]

If[! ValueQ[SourceVault`$SourceVaultKGRoot], SourceVault`$SourceVaultKGRoot = Automatic];
If[! ValueQ[SourceVault`$SourceVaultKGViewMaxRows], SourceVault`$SourceVaultKGViewMaxRows = 200];
If[! ValueQ[SourceVault`$SourceVaultKGTooHard], SourceVault`$SourceVaultKGTooHard = 0.6];

$kgSchemaVersion = 1;

(* ---------------- \:8fba\:30fb\:30ce\:30fc\:30c9\:7a2e\:5225 ----------------
   \:3059\:3079\:3066\:306e\:9806\:5e8f\:8fba\:306f\:300cFrom \:3092 To \:3088\:308a\:5148\:306b\:63d0\:793a\:3059\:308b\:300d\:5411\:304d\:3067\:66f8\:304f\:3002 *)
SourceVault`$SourceVaultKGEdgeKinds = <|
  "Prerequisite" -> <|"Order" -> True, "OrderKind" -> "Difficulty", "Parent" -> "From", "Affinity" -> 0.5|>,
  "Precedes" -> <|"Order" -> True, "OrderKind" -> "Temporal", "Parent" -> "From", "Affinity" -> 0.4|>,
  "Derives" -> <|"Order" -> True, "OrderKind" -> "Derivation", "Parent" -> "From", "Affinity" -> 0.8|>,
  "Motivates" -> <|"Order" -> True, "OrderKind" -> "Narrative", "Parent" -> "From", "Affinity" -> 0.7|>,
  "LeadsTo" -> <|"Order" -> True, "OrderKind" -> "Causal", "Parent" -> "From", "Affinity" -> 0.6|>,
  "Contains" -> <|"Order" -> True, "OrderKind" -> "Hierarchy", "Parent" -> "From", "Affinity" -> 1.0|>,
  "Supports" -> <|"Order" -> False, "OrderKind" -> None, "Parent" -> "To", "Affinity" -> 0.9|>,
  "Explains" -> <|"Order" -> False, "OrderKind" -> None, "Parent" -> "To", "Affinity" -> 0.9|>,
  "Contrasts" -> <|"Order" -> False, "OrderKind" -> None, "Parent" -> "Either", "Affinity" -> 0.3|>,
  "RelatedTo" -> <|"Order" -> False, "OrderKind" -> None, "Parent" -> "Either", "Affinity" -> 0.3|>,
  "Cites" -> <|"Order" -> False, "OrderKind" -> None, "Parent" -> "Either", "Affinity" -> 0.2|>|>;

SourceVault`$SourceVaultKGNodeKinds = {"Claim", "Concept", "Definition", "Method", "Experiment",
  "Result", "Equation", "Figure", "Question", "Conclusion", "Background", "Section", "Survey",
  "RelatedWork", "Example"};

$kgRootKinds = {"Claim", "Conclusion", "Survey"};
$kgTextKeys = {"Label", "Summary", "Talk", "Cite", "Lead", "Gist", "Role", "Bridge"};
$kgListTextKeys = {"Points", "Details"};

(* ---------------- \:4fdd\:5b58\:5834\:6240 ---------------- *)

iKGLocalFallbackRoot[] := Module[{base},
  base = Quiet @ Check[Environment["LOCALAPPDATA"], $Failed];
  If[! StringQ[base] || StringLength[base] === 0,
    base = Quiet @ Check[$TemporaryDirectory, "."]];
  FileNameJoin[{base, "SourceVault", "knowledgegraph"}]];

iKGResolveRoot[] := Module[{override, core},
  override = SourceVault`$SourceVaultKGRoot;
  If[StringQ[override] && StringLength[override] > 0, Return[override]];
  core = If[Length[DownValues[SourceVault`SourceVaultCoreRoot]] > 0,
    Quiet @ Check[SourceVault`SourceVaultCoreRoot[], $Failed], $Failed];
  If[StringQ[core] && StringLength[core] > 0,
    FileNameJoin[{core, "knowledgegraph"}],
    iKGLocalFallbackRoot[]]];

iKGEnsureDirectory[dir_String] := (
  If[! DirectoryQ[dir],
    Quiet @ Check[CreateDirectory[dir, CreateIntermediateDirectories -> True], Null]];
  dir);

SourceVaultKGRoot[] := iKGEnsureDirectory[iKGResolveRoot[]];
iKGGraphDir[] := iKGEnsureDirectory[FileNameJoin[{SourceVaultKGRoot[], "graphs"}]];
iKGHistoryDir[] := iKGEnsureDirectory[FileNameJoin[{SourceVaultKGRoot[], "graphs", "history"}]];
iKGBackgroundDir[] := iKGEnsureDirectory[FileNameJoin[{SourceVaultKGRoot[], "background"}]];

iKGUTCNow[] := DateString[TimeZoneConvert[Now, 0], "ISODateTime"] <> "Z";

(* ---------------- JSON I/O (SourceVault_slidedeck.wl \:3068\:540c\:3058\:5358\:4e00\:30a8\:30f3\:30b3\:30fc\:30c9) ---------------- *)

iKGJSONSafe[expr_] := expr /. {
  m_Missing :> Null, None -> Null,
  dt_DateObject :> DateString[dt, "ISODateTime"]};

$kgRetryCount = 5;
$kgRetryPause = 0.05;

iKGWriteJSON[path_String, data_] := Module[{ba, dir = DirectoryName[path], tmp, done},
  iKGEnsureDirectory[dir];
  ba = Quiet @ Check[ExportByteArray[iKGJSONSafe[data], "RawJSON"], $Failed];
  If[! ByteArrayQ[ba], Return[$Failed]];
  tmp = path <> ".tmp";
  done = False;
  Do[
    done = TrueQ @ Quiet @ Check[
      Module[{strm = OpenWrite[tmp, BinaryFormat -> True]},
        If[Head[strm] =!= OutputStream, Return[False, Module]];
        WithCleanup[BinaryWrite[strm, ba], Quiet @ Close[strm]];
        RenameFile[tmp, path, OverwriteTarget -> True];
        True],
      False];
    If[done, Break[]];
    Pause[$kgRetryPause],
    {$kgRetryCount}];
  If[done, path, $Failed]];

iKGReadJSON[path_String] := Module[{bytes, parsed},
  If[! FileExistsQ[path], Return[Missing["NoFile"]]];
  Do[
    bytes = Quiet @ Check[ReadByteArray[path], $Failed];
    If[ByteArrayQ[bytes],
      parsed = Quiet @ Check[ImportByteArray[bytes, "RawJSON"], $Failed];
      If[parsed =!= $Failed, Return[parsed, Module]]];
    Pause[$kgRetryPause],
    {$kgRetryCount}];
  If[ByteArrayQ[bytes], Missing["BadJSON"], Missing["Unreadable"]]];

iKGJSONString[data_] := Module[{ba},
  ba = Quiet @ Check[ExportByteArray[iKGJSONSafe[data], "RawJSON"], $Failed];
  If[ByteArrayQ[ba], ByteArrayToString[ba, "UTF-8"], $Failed]];

(* LLM \:5fdc\:7b54: ```json \:30d5\:30a7\:30f3\:30b9\:3084\:524d\:7f6e\:304d\:3092\:5265\:304c\:3057\:3066\:6700\:521d\:306e { .. \:6700\:5f8c\:306e } \:3092\:53d6\:308b *)
iKGParseJSONText[s_String] := Module[{t = s, a, b, parsed},
  t = StringReplace[t, {"```json" -> "", "```JSON" -> "", "```" -> ""}];
  a = StringPosition[t, "{", 1];
  b = StringPosition[t, "}"];
  If[a === {} || b === {}, Return[$Failed]];
  t = StringTake[t, {a[[1, 1]], b[[-1, 2]]}];
  parsed = Quiet @ Check[ImportByteArray[StringToByteArray[t, "UTF-8"], "RawJSON"], $Failed];
  If[parsed === $Failed,
    parsed = Quiet @ Check[ImportString[t, "RawJSON"], $Failed]];
  If[parsed === $Failed, parsed, iKGFixMojibakeDeep[parsed]]];

(* ---------------- \:6587\:5b57\:5316\:3051 (UTF-8 \:306e\:30d0\:30a4\:30c8\:3092 1 \:6587\:5b57\:305a\:3064\:8aad\:3093\:3060\:5f62) \:306e\:4fee\:5fa9 ----------------
   2026-09-28: \:5468\:8fba\:77e5\:8b58\:3092\:30a8\:30fc\:30b8\:30a7\:30f3\:30c8\:306b\:4f5c\:3089\:305b\:305f\:30b8\:30e3\:30ef\:8a9e\:306e\:30ce\:30fc\:30c9\:304c\:300cgaw\[EAcute]\:300d\[RightArrow]\:300cgaw\[CapitalATilde]\[Copyright]\:300d\:306e\:5f62\:3067
   \:4fdd\:5b58\:3055\:308c\:3066\:3044\:305f (JSON \:306b \u00c3\u00a9)\:3002\:53d6\:308a\:8fbc\:307f\:5074\:306f UTF-8 \:3067\:8aad\:3093\:3067\:3044\:308b\:306e\:3067\:3001\:6e21\:3055\:308c\:305f
   \:6587\:5b57\:5217\:304c\:65e2\:306b\:3053\:306e\:5f62\:3060\:3063\:305f (\:3069\:306e\:7d4c\:8def\:3067\:5316\:3051\:305f\:304b\:306f\:7279\:5b9a\:3067\:304d\:305a)\:3002\:5165\:53e3\:3067\:76f4\:3059\:3002
   UTF-8 \:306e\:5148\:982d\:30d0\:30a4\:30c8 (C2-F4) \:306b\:7d9a\:304f\:7d99\:7d9a\:30d0\:30a4\:30c8 (80-BF) \:306e\:4e26\:3073\:3092 1 \:584a\:3068\:3057\:3066 UTF-8 \:3067\:8aad\:307f\:76f4\:3057\:3001
   \:6b63\:3057\:304f\:8aad\:3081\:3066\:77ed\:304f\:306a\:3063\:305f\:3068\:304d\:3060\:3051\:7f6e\:304d\:63db\:3048\:308b\:3002\:65e5\:672c\:8a9e (U+0100 \:4ee5\:4e0a) \:3084\:5358\:72ec\:306e \[EAcute] \:306b\:306f\:89e6\:308c\:306a\:3044\:3002 *)
iKGFixMojibakeRun[r_String] := Module[{d},
  d = Quiet @ Check[ByteArrayToString[ByteArray[ToCharacterCode[r]], "UTF-8"], $Failed];
  If[StringQ[d] && StringFreeQ[d, "\[UnknownGlyph]"] && StringLength[d] < StringLength[r], d, r]];

iKGFixMojibake[s_String] := If[
  StringFreeQ[s, RegularExpression["[\\x{C2}-\\x{F4}][\\x{80}-\\x{BF}]"]], s,
  StringReplace[s, run : RegularExpression["[\\x{C2}-\\x{F4}][\\x{80}-\\x{BF}]+"] :> iKGFixMojibakeRun[run]]];
iKGFixMojibake[x_] := x;

(* \:5024\:3060\:3051\:3092\:305f\:3069\:308b (ReplaceAll \:3060\:3068\:9023\:60f3\:306e\:30ad\:30fc\:306b\:3082\:5f53\:305f\:308a\:3001\:30ad\:30fc\:304c\:672a\:8a55\:4fa1\:306e iKGFixMojibake[..] \:306e\:307e\:307e\:6b8b\:308b) *)
iKGFixMojibakeDeep[s_String] := iKGFixMojibake[s];
iKGFixMojibakeDeep[a_Association] := iKGFixMojibakeDeep /@ a;
iKGFixMojibakeDeep[l_List] := iKGFixMojibakeDeep /@ l;
iKGFixMojibakeDeep[x_] := x;

(* \:4fdd\:5b58\:6e08\:307f\:306e KG (graphs/*.json) \:3068\:5468\:8fba\:77e5\:8b58\:306e\:66f8\:5eab (background/*.json) \:3092\:76f4\:3059\:3002\:76f4\:3057\:305f\:30d5\:30a1\:30a4\:30eb\:306e\:6570\:3092\:8fd4\:3059 *)
SourceVaultKGRepairMojibake[] := Module[{files, fixed = {}},
  files = Join[
    FileNames["*.json", iKGGraphDir[]],
    FileNames["*.json", iKGBackgroundDir[]]];
  Do[
    With[{d = iKGReadJSON[f]},
      If[AssociationQ[d] || ListQ[d],
        With[{g = iKGFixMojibakeDeep[d]},
          If[g =!= d && StringQ[iKGWriteJSON[f, g]], AppendTo[fixed, f]]]]],
    {f, files}];
  <|"Checked" -> Length[files], "Fixed" -> Length[fixed], "Files" -> FileNameTake /@ fixed|>];

(* ---------------- \:5c0f\:3055\:306a\:9053\:5177 ---------------- *)

iKGStr[v_] := Which[StringQ[v], v, v === Null || MissingQ[v] || v === None, "", True, ToString[v]];
iKGNum[v_, default_] := If[NumericQ[v], N[v], default];
iKGClip[v_, default_] := If[NumericQ[v], Clip[N[v], {0., 1.}], default];
iKGList[v_] := Which[ListQ[v], v, v === Null || MissingQ[v] || v === None, {}, True, {v}];
iKGStrList[v_] := Select[iKGStr /@ iKGList[v], # =!= "" &];
iKGAssocQ[v_] := AssociationQ[v] || MatchQ[v, {___Rule}];
iKGAssoc[v_] := If[MatchQ[v, {___Rule}], Association[v], v];

iKGNormalizeKey[value_] := Module[{t},
  t = iKGStr[value];
  t = Quiet @ Check[CharacterNormalize[t, "NFKC"], t];
  If[! StringQ[t], t = iKGStr[value]];
  t = ToLowerCase[t];
  StringJoin @ Select[Characters[t], StringMatchQ[#, LetterCharacter | DigitCharacter] &]];

iKGBigrams[s_String] := With[{t = iKGNormalizeKey[s]},
  If[StringLength[t] < 2, {t}, StringPartition[t, 2, 1]]];
iKGBigramSimilarity[a_String, b_String] := Module[{x = iKGBigrams[a], y = iKGBigrams[b], u},
  u = Length[Union[x, y]];
  If[u === 0, 0., N[Length[Intersection[x, y]] / u]]];

iKGSlug[label_String] := With[{k = iKGNormalizeKey[label]},
  If[k === "", "node", StringTake[k, UpTo[48]]]];

(* \:8a00\:8a9e\:5225\:30c6\:30ad\:30b9\:30c8: String | <|lang -> String|> *)
iKGTextValue[v_String, ___] := v;
iKGTextValue[v_Association, lang_String, primary_String] := Module[{r},
  r = Lookup[v, lang, Lookup[v, primary, None]];
  If[! StringQ[r] || r === "",
    r = FirstCase[Values[v], s_String /; s =!= "", ""]];
  r];
iKGTextValue[v_List, ___] := v;
iKGTextValue[_, ___] := "";

iKGListValue[v_List, ___] := iKGStrList[v];
iKGListValue[v_Association, lang_String, primary_String] := Module[{r},
  r = Lookup[v, lang, Lookup[v, primary, None]];
  If[! ListQ[r] || r === {}, r = FirstCase[Values[v], l_List /; l =!= {}, {}]];
  iKGStrList[r]];
iKGListValue[v_String, ___] := If[v === "", {}, {v}];
iKGListValue[_, ___] := {};

iKGHasLanguageQ[v_String, lang_, primary_] := lang === primary;
iKGHasLanguageQ[v_Association, lang_, _] := StringQ[Lookup[v, lang, None]] || ListQ[Lookup[v, lang, None]];
iKGHasLanguageQ[v_List, lang_, primary_] := lang === primary;
iKGHasLanguageQ[___] := True;

(* \:30c6\:30ad\:30b9\:30c8\:9023\:60f3\:306e\:6b63\:898f\:5316: String \:306f\:305d\:306e\:307e\:307e\:3001\:9023\:60f3\:306f\:8a00\:8a9e\:30ad\:30fc\:306e String \:3060\:3051\:6b8b\:3059 *)
iKGNormText[v_String] := StringTrim[v];
iKGNormText[v_?iKGAssocQ] := Module[{a = iKGAssoc[v]},
  a = KeySelect[Select[a, StringQ], StringQ];
  Which[Length[a] === 0, "", Length[a] === 1, First[a], True, a]];
iKGNormText[v_List] := StringRiffle[iKGStrList[v], " "];
iKGNormText[_] := "";

iKGNormListText[v_List] := iKGStrList[v];
iKGNormListText[v_?iKGAssocQ] := Module[{a = iKGAssoc[v]},
  a = KeySelect[Map[iKGStrList, Select[a, ListQ]], StringQ];
  Which[Length[a] === 0, {}, Length[a] === 1, First[a], True, a]];
iKGNormListText[v_String] := If[StringTrim[v] === "", {}, {v}];
iKGNormListText[_] := {};

SourceVaultKGText[node_Association, key_String, lang_String : "ja"] := Module[
  {primary = iKGStr[Lookup[node, "PrimaryLanguage", "ja"]], v = Lookup[node, key, None]},
  If[primary === "", primary = "ja"];
  If[MemberQ[$kgListTextKeys, key], iKGListValue[v, lang, primary],
    With[{r = iKGTextValue[v, lang, primary]}, If[StringQ[r], r, ""]]]];
SourceVaultKGText[_, _, ___] := "";

(* ---------------- \:6b63\:898f\:5316\:3068\:691c\:8a3c ---------------- *)

iKGNormalizeNode[n_?iKGAssocQ, primary_String] := Module[{e = iKGAssoc[n], id, kind, layer},
  id = StringTrim @ iKGStr[Lookup[e, "Id", Lookup[e, "id", ""]]];
  If[id === "", Return[$Failed]];
  e = KeyMap[ToString, e];
  e["Id"] = id;
  kind = iKGStr[Lookup[e, "Kind", "Concept"]];
  If[! MemberQ[SourceVault`$SourceVaultKGNodeKinds, kind], kind = "Concept"];
  e["Kind"] = kind;
  Do[e[k] = iKGNormText[Lookup[e, k, ""]], {k, $kgTextKeys}];
  Do[e[k] = iKGNormListText[Lookup[e, k, {}]], {k, $kgListTextKeys}];
  If[e["Label"] === "", e["Label"] = id];
  e["Difficulty"] = iKGClip[Lookup[e, "Difficulty", 0.5], 0.5];
  e["Importance"] = iKGClip[Lookup[e, "Importance", 0.5], 0.5];
  e["Domains"] = iKGStrList[Lookup[e, "Domains", {}]];
  e["Aliases"] = iKGStrList[Lookup[e, "Aliases", {}]];
  e["Year"] = With[{y = Lookup[e, "Year", None]}, If[IntegerQ[y], y, None]];
  e["Order"] = With[{o = Lookup[e, "Order", None]}, If[NumericQ[o], o, None]];
  layer = iKGStr[Lookup[e, "Layer", ""]];
  If[! MemberQ[{"Paper", "Background", "Shared"}, layer],
    layer = If[kind === "Background", "Background", "Paper"]];
  e["Layer"] = layer;
  e["Assets"] = Select[iKGAssoc /@ Select[iKGList[Lookup[e, "Assets", {}]], iKGAssocQ],
    StringQ[Lookup[#, "Type", None]] &];
  e["PrivacyLevel"] = iKGClip[Lookup[e, "PrivacyLevel", 0.], 0.];
  e["PrimaryLanguage"] = primary;
  e["Source"] = With[{s = Lookup[e, "Source", <||>]}, If[iKGAssocQ[s], iKGAssoc[s], <||>]];
  e["BackgroundRef"] = With[{b = Lookup[e, "BackgroundRef", None]}, If[StringQ[b] && b =!= "", b, None]];
  (* v1.42: \:300c\:5fc5\:305a\:51fa\:3059\:300d\:5370 (\:8a08\:753b\:306f\:70b9\:6570\:306b\:3088\:3089\:305a\:67a0\:3092\:53d6\:308b) \:3068\:56f3\:306e\:4e26\:3079\:65b9 ("Row" = \:6a2a\:4e26\:3073) *)
  If[KeyExistsQ[e, "Pinned"], e["Pinned"] = TrueQ[e["Pinned"]]];
  If[KeyExistsQ[e, "FigureLayout"],
    e["FigureLayout"] = If[StringContainsQ[ToLowerCase[iKGStr[e["FigureLayout"]]], "row" | "\:6a2a"], "Row", "Column"]];
  (* v1.44: \:968e\:5c64\:5316\:3067\:8db3\:3057\:305f\:300c\:307e\:3068\:307e\:308a\:300d\:306e\:30ce\:30fc\:30c9 *)
  If[KeyExistsQ[e, "Cluster"], e["Cluster"] = TrueQ[e["Cluster"]]];
  (* v1.46: \:76ee\:6b21\:306e\:7bc0\:3068\:3001\:8074\:304d\:624b\:306b\:5411\:3051\:305f\:8981\:5426 (Must = \:5fc5\:305a / Optional = \:679a\:6570\:3057\:3060\:3044 / Omit = \:51fa\:3055\:306a\:3044) *)
  If[KeyExistsQ[e, "Toc"], e["Toc"] = TrueQ[e["Toc"]]];
  If[KeyExistsQ[e, "Include"], e["Include"] = With[{s = ToLowerCase[iKGStr[e["Include"]]]},
    Which[StringContainsQ[s, "must" | "\:5fc5"], "Must", StringContainsQ[s, "omit" | "\:7701" | "\:51fa\:3055"], "Omit", True, "Optional"]]];
  e];
iKGNormalizeNode[___] := $Failed;

(* \:691c\:8a3c\:4e2d\:306e\:8b66\:544a\:306f\:52d5\:7684\:30b9\:30b3\:30fc\:30d7\:306e $kgWarn \:306b\:96c6\:3081\:308b (\:5f15\:6570\:306e\:53c2\:7167\:6e21\:3057\:306f WL \:3067\:306f\:8a55\:4fa1\:6e08\:307f\:306e\:5024\:306b\:306a\:308b) *)
$kgWarn = {};

iKGNormalizeEdge[ed_?iKGAssocQ] := Module[{e = iKGAssoc[ed], kind, spec},
  e = KeyMap[ToString, e];
  e["From"] = StringTrim @ iKGStr[Lookup[e, "From", Lookup[e, "from", ""]]];
  e["To"] = StringTrim @ iKGStr[Lookup[e, "To", Lookup[e, "to", ""]]];
  If[e["From"] === "" || e["To"] === "", Return[$Failed]];
  kind = iKGStr[Lookup[e, "EdgeKind", Lookup[e, "Kind", Lookup[e, "Relation", "RelatedTo"]]]];
  If[! KeyExistsQ[SourceVault`$SourceVaultKGEdgeKinds, kind],
    AppendTo[$kgWarn, "UnknownEdgeKind: " <> kind <> " -> RelatedTo"];
    kind = "RelatedTo"];
  spec = SourceVault`$SourceVaultKGEdgeKinds[kind];
  e["EdgeKind"] = kind;
  e["Weight"] = iKGClip[Lookup[e, "Weight", 0.5], 0.5];
  e["Confidence"] = iKGClip[Lookup[e, "Confidence", 0.7], 0.7];
  e["Order"] = With[{o = Lookup[e, "Order", Automatic]},
    If[BooleanQ[o], o, TrueQ[spec["Order"]]]];
  e["OrderKind"] = With[{k = Lookup[e, "OrderKind", None]},
    If[StringQ[k] && k =!= "", k, spec["OrderKind"]]];
  e["EvidenceRefs"] = iKGStrList[Lookup[e, "EvidenceRefs", {}]];
  KeyTake[e, {"From", "To", "EdgeKind", "Weight", "Confidence", "Order", "OrderKind", "EvidenceRefs"}]];
iKGNormalizeEdge[___] := $Failed;

iKGPickRoot[nodes_List, explicit_] := Module[{ids = Lookup[nodes, "Id"], cand},
  If[StringQ[explicit] && MemberQ[ids, explicit], Return[explicit]];
  cand = Select[nodes, MemberQ[$kgRootKinds, #["Kind"]] &];
  If[cand === {}, cand = nodes];
  If[cand === {}, None, First[MaximalBy[cand, #["Importance"] &]]["Id"]]];

Options[SourceVaultKGNew] = {"Title" -> "", "Language" -> "ja", "Sources" -> {},
  "Kind" -> "Paper", "PrivacyLevel" -> 0.};
SourceVaultKGNew[graphId_String, OptionsPattern[]] := <|
  "ObjectClass" -> "SourceVaultKnowledgeGraph", "SchemaVersion" -> $kgSchemaVersion,
  "GraphId" -> graphId, "Title" -> iKGStr[OptionValue["Title"]],
  "Kind" -> iKGStr[OptionValue["Kind"]], "Language" -> iKGStr[OptionValue["Language"]],
  "Sources" -> Select[iKGAssoc /@ Select[iKGList[OptionValue["Sources"]], iKGAssocQ], AssociationQ],
  "PrivacyLevel" -> iKGClip[OptionValue["PrivacyLevel"], 0.],
  "Nodes" -> {}, "Edges" -> {}, "Root" -> None, "Warnings" -> {},
  "UpdatedAtUTC" -> iKGUTCNow[]|>;

SourceVaultKGValidate[kgIn_?iKGAssocQ] := Block[{$kgWarn = {}}, iKGValidate[kgIn]];

iKGValidate[kgIn_] := Module[
  {kg = KeyMap[ToString, iKGAssoc[kgIn]], primary, nodes, ids, seen, edges, warnings = {}, root},
  primary = iKGStr[Lookup[kg, "Language", "ja"]];
  If[primary === "", primary = "ja"];
  kg["Language"] = primary;
  kg["ObjectClass"] = "SourceVaultKnowledgeGraph";
  kg["SchemaVersion"] = $kgSchemaVersion;
  kg["GraphId"] = With[{g = iKGStr[Lookup[kg, "GraphId", Lookup[kg, "graphId", ""]]]},
    If[g === "", "kg-" <> StringTake[CreateUUID[], 8], g]];
  kg["Title"] = iKGStr[Lookup[kg, "Title", ""]];
  kg["Kind"] = With[{k = iKGStr[Lookup[kg, "Kind", "Paper"]]},
    If[MemberQ[{"Paper", "Survey", "Background", "Scenario", "Notebook"}, k], k, "Paper"]];
  kg["PrivacyLevel"] = iKGClip[Lookup[kg, "PrivacyLevel", 0.], 0.];
  kg["Sources"] = Select[iKGAssoc /@ Select[iKGList[Lookup[kg, "Sources", {}]], iKGAssocQ], AssociationQ];
  nodes = DeleteCases[iKGNormalizeNode[#, primary] & /@ iKGList[Lookup[kg, "Nodes", {}]], $Failed];
  (* \:540c\:3058 Id \:306f\:5148\:52dd\:3061 *)
  seen = <||>;
  nodes = Select[nodes, Function[n,
    If[KeyExistsQ[seen, n["Id"]],
      AppendTo[warnings, "DuplicateNode: " <> n["Id"]]; False,
      seen[n["Id"]] = True; True]]];
  ids = Lookup[nodes, "Id", {}];
  edges = DeleteCases[iKGNormalizeEdge /@ iKGList[Lookup[kg, "Edges", {}]], $Failed];
  warnings = Join[warnings, $kgWarn];
  edges = Select[edges, Function[e,
    Which[
      e["From"] === e["To"], AppendTo[warnings, "SelfLoop: " <> e["From"]]; False,
      ! MemberQ[ids, e["From"]] || ! MemberQ[ids, e["To"]],
        AppendTo[warnings, "DanglingEdge: " <> e["From"] <> " -> " <> e["To"]]; False,
      True, True]]];
  edges = DeleteDuplicatesBy[edges, {#["From"], #["To"], #["EdgeKind"]} &];
  root = iKGPickRoot[nodes, Lookup[kg, "Root", None]];
  kg["Nodes"] = nodes;
  kg["Edges"] = edges;
  kg["Root"] = root;
  kg["Warnings"] = warnings;
  kg["UpdatedAtUTC"] = iKGUTCNow[];
  kg];
SourceVaultKGValidate[_] := Failure["NotAGraph", <|"MessageTemplate" -> "expected an Association"|>];

SourceVaultKGFromJSON[s_String] := Module[{parsed = iKGParseJSONText[s]},
  If[! iKGAssocQ[parsed],
    Return[Failure["BadJSON", <|"MessageTemplate" -> "could not parse a JSON object from the text"|>]]];
  SourceVaultKGFromJSON[parsed]];
SourceVaultKGFromJSON[a_?iKGAssocQ] := Module[{kg = SourceVaultKGValidate[iKGFixMojibakeDeep[a]]},
  If[! AssociationQ[kg], Return[kg]];
  If[kg["Nodes"] === {},
    Return[Failure["NoNodes", <|"MessageTemplate" -> "the graph has no nodes"|>]]];
  kg];
SourceVaultKGFromJSON[_] := Failure["BadJSON", <|"MessageTemplate" -> "expected JSON text or an Association"|>];

SourceVaultKGToJSON[kg_Association] := iKGJSONString[kg];

SourceVaultKGNode[kg_Association, id_String] :=
  FirstCase[Lookup[kg, "Nodes", {}], n_Association /; n["Id"] === id, Missing["NoNode", id]];

iKGNodeIndex[kg_Association] := AssociationMap[SourceVaultKGNode[kg, #] &, Lookup[Lookup[kg, "Nodes", {}], "Id", {}]];
iKGNodeIndex[kg_Association] := Association[(#["Id"] -> #) & /@ Lookup[kg, "Nodes", {}]];

(* ---------------- \:5dee\:5206\:53d6\:308a\:8fbc\:307f ---------------- *)

iKGMergeText[old_, new_String, lang_String, primary_String] := Which[
  new === "", old,
  lang === primary && (old === "" || StringQ[old]), new,
  StringQ[old] && old === "", <|lang -> new|>,
  StringQ[old], <|primary -> old, lang -> new|>,
  AssociationQ[old], Append[old, lang -> new],
  True, new];
iKGMergeText[old_, new_Association, ___] := Which[
  StringQ[old] && old =!= "", Join[<|"ja" -> old|>, new],
  AssociationQ[old], Join[old, new],
  True, new];
iKGMergeText[old_, _, ___] := old;

iKGMergeListText[old_, new_List, lang_String, primary_String] := Which[
  new === {}, old,
  lang === primary && (old === {} || ListQ[old]), new,
  ListQ[old] && old === {}, <|lang -> new|>,
  ListQ[old], <|primary -> old, lang -> new|>,
  AssociationQ[old], Append[old, lang -> new],
  True, new];
iKGMergeListText[old_, new_Association, ___] := If[AssociationQ[old], Join[old, new], new];
iKGMergeListText[old_, _, ___] := old;

Options[SourceVaultKGMerge] = {"Language" -> Automatic};
SourceVaultKGMerge[kg_Association, deltaIn_, OptionsPattern[]] := Module[
  {delta, primary = iKGStr[Lookup[kg, "Language", "ja"]], lang, index, newNodes, e2, nodes, edges, res},
  delta = Which[StringQ[deltaIn], iKGParseJSONText[deltaIn], iKGAssocQ[deltaIn], iKGFixMojibakeDeep[iKGAssoc[deltaIn]], True, $Failed];
  If[! iKGAssocQ[delta], Return[Failure["BadDelta", <|"MessageTemplate" -> "delta must be JSON text or an Association"|>]]];
  delta = KeyMap[ToString, delta];
  lang = Replace[OptionValue["Language"], Automatic -> primary];
  index = iKGNodeIndex[kg];
  newNodes = Select[iKGAssoc /@ Select[iKGList[Lookup[delta, "Nodes", {}]], iKGAssocQ], AssociationQ];
  Do[
    Module[{id = StringTrim @ iKGStr[Lookup[n, "Id", Lookup[n, "id", ""]]], old, m},
      If[id === "", Continue[]];
      m = KeyMap[ToString, n];
      If[KeyExistsQ[index, id],
        old = index[id];
        Do[If[KeyExistsQ[m, k],
          old[k] = iKGMergeText[Lookup[old, k, ""], iKGNormText[m[k]], lang, primary]],
          {k, $kgTextKeys}];
        Do[If[KeyExistsQ[m, k],
          old[k] = iKGMergeListText[Lookup[old, k, {}], iKGNormListText[m[k]], lang, primary]],
          {k, $kgListTextKeys}];
        Do[If[KeyExistsQ[m, k], old[k] = m[k]],
          {k, Complement[Keys[m], Join[$kgTextKeys, $kgListTextKeys, {"Id", "id"}]]}];
        If[KeyExistsQ[m, "Aliases"], old["Aliases"] = Union[iKGStrList[Lookup[old, "Aliases", {}]], iKGStrList[m["Aliases"]]]];
        If[KeyExistsQ[m, "Domains"], old["Domains"] = Union[iKGStrList[Lookup[old, "Domains", {}]], iKGStrList[m["Domains"]]]];
        index[id] = old,
        (* \:65b0\:898f\:30ce\:30fc\:30c9: \:4e3b\:8a00\:8a9e\:3067\:306a\:3044\:8a33\:3060\:3051\:3092\:6301\:305f\:305b\:306a\:3044 (\:30e9\:30d9\:30eb\:306f\:5fc5\:8981) *)
        If[lang =!= primary,
          Do[If[KeyExistsQ[m, k] && StringQ[m[k]], m[k] = <|lang -> m[k]|>], {k, $kgTextKeys}];
          Do[If[KeyExistsQ[m, k] && ListQ[m[k]], m[k] = <|lang -> m[k]|>], {k, $kgListTextKeys}]];
        m["Id"] = id;
        index[id] = m]],
    {n, newNodes}];
  (* "Remove": \:30ce\:30fc\:30c9\:3092\:843d\:3068\:3057\:3001\:305d\:306e\:30ce\:30fc\:30c9\:306b\:89e6\:308c\:308b\:8fba\:3082\:843d\:3068\:3059 (\:63a8\:6572\:3067\:6bb5\:843d\:3092\:7d71\:5408\:3059\:308b\:3068\:304d) *)
  Do[KeyDropFrom[index, r], {r, iKGStrList[Lookup[delta, "Remove", {}]]}];
  nodes = Values[index];
  e2 = Select[iKGAssoc /@ Select[iKGList[Lookup[delta, "Edges", {}]], iKGAssocQ], AssociationQ];
  edges = Select[Join[Lookup[kg, "Edges", {}], e2],
    KeyExistsQ[index, iKGStr[Lookup[#, "From", ""]]] && KeyExistsQ[index, iKGStr[Lookup[#, "To", ""]]] &];
  (* \:63a8\:6572\:3084\:5468\:8fba\:77e5\:8b58\:3092\:56de\:3059\:305f\:3073\:306b\:540c\:3058\:8fba\:304c\:7a4d\:307f\:91cd\:306a\:308b (\:5b9f\:6e2c: \:540c\:3058\:5411\:304d\:306e\:8fba\:304c 2 \:672c\:305a\:3064)\:3002\:7a2e\:985e\:3054\:3068\:306b 1 \:672c\:3001\:5f8c\:306e\:3082\:306e\:3092\:6b8b\:3059 *)
  edges = Reverse[DeleteDuplicatesBy[Reverse[edges],
    {iKGStr[Lookup[#, "From", ""]], iKGStr[Lookup[#, "To", ""]], iKGStr[Lookup[#, "EdgeKind", ""]]} &]];
  res = SourceVaultKGValidate[Join[kg, <|"Nodes" -> nodes, "Edges" -> edges,
    "Root" -> Lookup[delta, "Root", Lookup[kg, "Root", None]]|>]];
  If[AssociationQ[res],
    res["Warnings"] = Join[Lookup[kg, "Warnings", {}], Lookup[res, "Warnings", {}]] // DeleteDuplicates];
  res];

(* ---------------- \:4fdd\:5b58 / \:8aad\:8fbc ---------------- *)

iKGGraphFile[graphId_String] := FileNameJoin[{iKGGraphDir[], iKGSlug[graphId] <> ".json"}];

SourceVaultKGSave[kgIn_Association] := Module[{kg = iKGFixMojibakeDeep[kgIn], path, prev, hist},
  (* \:5316\:3051\:305f\:307e\:307e\:899a\:3048\:3066\:3044\:308b KG \:3092\:66f8\:304d\:623b\:3055\:306a\:3044 (\:4fee\:5fa9\:3088\:308a\:524d\:306b\:8aad\:307f\:8fbc\:3093\:3060\:30ab\:30fc\:30cd\:30eb\:304b\:3089\:4fdd\:5b58\:3055\:308c\:3066\:3082\:76f4\:308b) *)
  If[! StringQ[Lookup[kg, "GraphId", None]], Return[$Failed]];
  path = iKGGraphFile[kg["GraphId"]];
  If[FileExistsQ[path],
    prev = Quiet @ Check[ReadByteArray[path], $Failed];
    If[ByteArrayQ[prev],
      hist = FileNameJoin[{iKGHistoryDir[],
        iKGSlug[kg["GraphId"]] <> "-" <> StringReplace[iKGUTCNow[], {":" -> "", "-" -> ""}] <> ".json"}];
      Quiet @ Check[
        Module[{strm = OpenWrite[hist, BinaryFormat -> True]},
          WithCleanup[BinaryWrite[strm, prev], Quiet @ Close[strm]]], Null]]];
  iKGWriteJSON[path, Append[kg, "UpdatedAtUTC" -> iKGUTCNow[]]]];

SourceVaultKGLoad[graphId_String] := Module[{d = iKGReadJSON[iKGGraphFile[graphId]]},
  If[MissingQ[d], d, SourceVaultKGValidate[iKGFixMojibakeDeep[d]]]];

SourceVaultKGList[] := Module[{files},
  files = Quiet @ Check[FileNames["*.json", iKGGraphDir[]], {}];
  Select[Map[Function[f, With[{d = iKGReadJSON[f]},
    If[! AssociationQ[d], Nothing,
      <|"GraphId" -> iKGStr[Lookup[d, "GraphId", ""]], "Title" -> iKGStr[Lookup[d, "Title", ""]],
        "Kind" -> iKGStr[Lookup[d, "Kind", ""]],
        "NodeCount" -> Length[iKGList[Lookup[d, "Nodes", {}]]],
        "EdgeCount" -> Length[iKGList[Lookup[d, "Edges", {}]]],
        "UpdatedAtUTC" -> iKGStr[Lookup[d, "UpdatedAtUTC", ""]], "File" -> f|>]]], files], AssociationQ]];

SourceVaultKGDelete[graphId_String] := With[{p = iKGGraphFile[graphId]},
  If[FileExistsQ[p], Quiet @ Check[DeleteFile[p]; True, False], False]];

(* ---------------- \:8074\:304d\:624b\:30e2\:30c7\:30eb ---------------- *)

SourceVault`$SourceVaultKGDomainAliases = <|
  "electrochemistry" -> "\:96fb\:6c17\:5316\:5b66", "hydrogel" -> "\:30cf\:30a4\:30c9\:30ed\:30b2\:30eb", "hydrogels" -> "\:30cf\:30a4\:30c9\:30ed\:30b2\:30eb",
  "polymer" -> "\:9ad8\:5206\:5b50", "polymers" -> "\:9ad8\:5206\:5b50", "materials" -> "\:6750\:6599\:79d1\:5b66", "materials science" -> "\:6750\:6599\:79d1\:5b66",
  "machine learning" -> "\:6a5f\:68b0\:5b66\:7fd2", "reinforcement learning" -> "\:5f37\:5316\:5b66\:7fd2", "deep learning" -> "\:6df1\:5c64\:5b66\:7fd2",
  "neural network" -> "\:30cb\:30e5\:30fc\:30e9\:30eb\:30cd\:30c3\:30c8", "neural networks" -> "\:30cb\:30e5\:30fc\:30e9\:30eb\:30cd\:30c3\:30c8",
  "calculus" -> "\:5fae\:7a4d\:5206", "linear algebra" -> "\:7dda\:5f62\:4ee3\:6570", "differential equations" -> "\:5fae\:5206\:65b9\:7a0b\:5f0f",
  "statistics" -> "\:7d71\:8a08", "probability" -> "\:78ba\:7387", "mathematics" -> "\:6570\:5b66", "math" -> "\:6570\:5b66",
  "physics" -> "\:7269\:7406", "chemistry" -> "\:5316\:5b66", "biology" -> "\:751f\:7269\:5b66", "neuroscience" -> "\:795e\:7d4c\:79d1\:5b66",
  "thermodynamics" -> "\:71b1\:529b\:5b66", "electromagnetism" -> "\:96fb\:78c1\:6c17\:5b66", "general relativity" -> "\:4e00\:822c\:76f8\:5bfe\:8ad6",
  "computer science" -> "\:8a08\:7b97\:6a5f\:79d1\:5b66", "programming" -> "\:30d7\:30ed\:30b0\:30e9\:30df\:30f3\:30b0", "network" -> "\:30cd\:30c3\:30c8\:30ef\:30fc\:30af",
  "networking" -> "\:30cd\:30c3\:30c8\:30ef\:30fc\:30af", "control theory" -> "\:5236\:5fa1", "control" -> "\:5236\:5fa1",
  "cellular automata" -> "\:30bb\:30eb\:30aa\:30fc\:30c8\:30de\:30c8\:30f3", "cellular automaton" -> "\:30bb\:30eb\:30aa\:30fc\:30c8\:30de\:30c8\:30f3",
  "complex systems" -> "\:8907\:96d1\:7cfb", "emergence" -> "\:5275\:767a", "unconventional computing" -> "\:975e\:5f93\:6765\:578b\:8a08\:7b97",
  "reservoir computing" -> "\:30ea\:30b6\:30d0\:30fc\:8a08\:7b97", "game theory" -> "\:30b2\:30fc\:30e0\:7406\:8ad6", "optics" -> "\:5149\:5b66",
  "high school math" -> "\:9ad8\:6821\:6570\:5b66", "high school physics" -> "\:9ad8\:6821\:7269\:7406", "high school chemistry" -> "\:9ad8\:6821\:5316\:5b66"|>;

SourceVault`$SourceVaultKGAudiencePresets = <|
  "\:4e00\:822c" -> <|"Level" -> 0.2, "Knowledge" -> <||>|>,
  "\:5c0f\:5b66\:751f" -> <|"Level" -> 0.05, "Knowledge" -> <|"\:7b97\:6570" -> 0.3|>|>,
  "\:4e2d\:5b66\:751f" -> <|"Level" -> 0.15, "Knowledge" -> <|"\:6570\:5b66" -> 0.2, "\:7406\:79d1" -> 0.2|>|>,
  "\:9ad8\:6821\:751f" -> <|"Level" -> 0.3, "Knowledge" -> <|"\:9ad8\:6821\:6570\:5b66" -> 0.5, "\:9ad8\:6821\:7269\:7406" -> 0.4, "\:9ad8\:6821\:5316\:5b66" -> 0.4, "\:6570\:5b66" -> 0.35, "\:7269\:7406" -> 0.3, "\:5316\:5b66" -> 0.3|>|>,
  "\:5927\:5b66\:7406\:7cfb\:5b66\:90e8\:5352" -> <|"Level" -> 0.5, "Knowledge" -> <|"\:6570\:5b66" -> 0.6, "\:5fae\:7a4d\:5206" -> 0.7, "\:7dda\:5f62\:4ee3\:6570" -> 0.6, "\:7269\:7406" -> 0.6, "\:5316\:5b66" -> 0.55, "\:30d7\:30ed\:30b0\:30e9\:30df\:30f3\:30b0" -> 0.5, "\:7d71\:8a08" -> 0.5|>|>,
  "\:5927\:5b66\:6587\:7cfb\:5b66\:90e8\:5352" -> <|"Level" -> 0.35, "Knowledge" -> <|"\:6570\:5b66" -> 0.3, "\:7d71\:8a08" -> 0.3|>|>,
  "\:5927\:5b66\:9662\:751f" -> <|"Level" -> 0.65, "Knowledge" -> <|"\:6570\:5b66" -> 0.7, "\:7269\:7406" -> 0.65, "\:30d7\:30ed\:30b0\:30e9\:30df\:30f3\:30b0" -> 0.6|>|>,
  "\:7814\:7a76\:8005" -> <|"Level" -> 0.85, "Knowledge" -> <|"\:6570\:5b66" -> 0.8, "\:7269\:7406" -> 0.75|>|>,
  "\:540c\:5206\:91ce\:306e\:7814\:7a76\:8005" -> <|"Level" -> 0.95, "Knowledge" -> <||>|>,
  "IT\:30a8\:30f3\:30b8\:30cb\:30a2" -> <|"Level" -> 0.45, "Knowledge" -> <|"\:30d7\:30ed\:30b0\:30e9\:30df\:30f3\:30b0" -> 0.9, "\:8a08\:7b97\:6a5f\:79d1\:5b66" -> 0.7, "\:30cd\:30c3\:30c8\:30ef\:30fc\:30af" -> 0.7, "\:6a5f\:68b0\:5b66\:7fd2" -> 0.5, "\:6570\:5b66" -> 0.5|>|>,
  "\:30cd\:30c3\:30c8\:30ef\:30fc\:30af\:30a8\:30f3\:30b8\:30cb\:30a2" -> <|"Level" -> 0.45, "Knowledge" -> <|"\:30cd\:30c3\:30c8\:30ef\:30fc\:30af" -> 0.95, "\:30d7\:30ed\:30b0\:30e9\:30df\:30f3\:30b0" -> 0.6, "\:8a08\:7b97\:6a5f\:79d1\:5b66" -> 0.6|>|>,
  "\:57fa\:672c\:60c5\:5831\:6280\:8853\:8005" -> <|"Level" -> 0.4, "Knowledge" -> <|"\:8a08\:7b97\:6a5f\:79d1\:5b66" -> 0.6, "\:30d7\:30ed\:30b0\:30e9\:30df\:30f3\:30b0" -> 0.6, "\:30cd\:30c3\:30c8\:30ef\:30fc\:30af" -> 0.5, "\:6570\:5b66" -> 0.4|>|>,
  "\:9ad8\:6821\:6570\:5b66III" -> <|"Level" -> 0., "Knowledge" -> <|"\:9ad8\:6821\:6570\:5b66" -> 0.9, "\:5fae\:7a4d\:5206" -> 0.75, "\:6570\:5b66" -> 0.6|>|>,
  "\:4e00\:822c\:76f8\:5bfe\:8ad6" -> <|"Level" -> 0., "Knowledge" -> <|"\:4e00\:822c\:76f8\:5bfe\:8ad6" -> 0.8, "\:5fae\:5206\:5e7e\:4f55" -> 0.6, "\:7269\:7406" -> 0.75, "\:6570\:5b66" -> 0.7|>|>,
  "\:96fb\:6c17\:5316\:5b66" -> <|"Level" -> 0., "Knowledge" -> <|"\:96fb\:6c17\:5316\:5b66" -> 0.8, "\:5316\:5b66" -> 0.7|>|>,
  "\:6a5f\:68b0\:5b66\:7fd2" -> <|"Level" -> 0., "Knowledge" -> <|"\:6a5f\:68b0\:5b66\:7fd2" -> 0.8, "\:7d71\:8a08" -> 0.6, "\:30d7\:30ed\:30b0\:30e9\:30df\:30f3\:30b0" -> 0.7|>|>,
  (* English aliases of the presets above *)
  "general public" -> <|"Level" -> 0.2, "Knowledge" -> <||>|>,
  "high school" -> <|"Level" -> 0.3, "Knowledge" -> <|"\:9ad8\:6821\:6570\:5b66" -> 0.5, "\:9ad8\:6821\:7269\:7406" -> 0.4, "\:9ad8\:6821\:5316\:5b66" -> 0.4, "\:6570\:5b66" -> 0.35, "\:7269\:7406" -> 0.3, "\:5316\:5b66" -> 0.3|>|>,
  "undergraduate" -> <|"Level" -> 0.5, "Knowledge" -> <|"\:6570\:5b66" -> 0.6, "\:5fae\:7a4d\:5206" -> 0.7, "\:7dda\:5f62\:4ee3\:6570" -> 0.6, "\:7269\:7406" -> 0.6, "\:5316\:5b66" -> 0.55, "\:30d7\:30ed\:30b0\:30e9\:30df\:30f3\:30b0" -> 0.5, "\:7d71\:8a08" -> 0.5|>|>,
  "graduate" -> <|"Level" -> 0.65, "Knowledge" -> <|"\:6570\:5b66" -> 0.7, "\:7269\:7406" -> 0.65, "\:30d7\:30ed\:30b0\:30e9\:30df\:30f3\:30b0" -> 0.6|>|>,
  "researcher" -> <|"Level" -> 0.85, "Knowledge" -> <|"\:6570\:5b66" -> 0.8, "\:7269\:7406" -> 0.75|>|>,
  "software engineer" -> <|"Level" -> 0.45, "Knowledge" -> <|"\:30d7\:30ed\:30b0\:30e9\:30df\:30f3\:30b0" -> 0.9, "\:8a08\:7b97\:6a5f\:79d1\:5b66" -> 0.7, "\:30cd\:30c3\:30c8\:30ef\:30fc\:30af" -> 0.7, "\:6a5f\:68b0\:5b66\:7fd2" -> 0.5, "\:6570\:5b66" -> 0.5|>|>,
  "network engineer" -> <|"Level" -> 0.45, "Knowledge" -> <|"\:30cd\:30c3\:30c8\:30ef\:30fc\:30af" -> 0.95, "\:30d7\:30ed\:30b0\:30e9\:30df\:30f3\:30b0" -> 0.6, "\:8a08\:7b97\:6a5f\:79d1\:5b66" -> 0.6|>|>|>;

(* \:9818\:57df\:540d\:306e\:6b63\:898f\:5316\:306f\:7d50\:679c\:3092\:899a\:3048\:3066\:304a\:304f\:3002\:8074\:304d\:624b\:306e\:5fc5\:8981\:5ea6 (SourceVaultKGScores) \:306f\:30ce\:30fc\:30c9 \[Times] \:9818\:57df \[Times] \:8074\:304d\:624b\:306e\:77e5\:8b58\:306e
   \:7d44\:3054\:3068\:306b\:5225\:540d\:8f9e\:66f8\:306e\:5168\:30ad\:30fc\:3092\:6b63\:898f\:5316\:3057\:76f4\:3057\:3066\:304a\:308a\:3001166 \:30ce\:30fc\:30c9\:306e KG \:3067\:8a08\:753b 1 \:56de\:306b\:7d04 6 \:79d2\:304b\:304b\:3063\:3066\:3044\:305f
   (\:300c\:751f\:6210\:300d\:3092\:62bc\:3057\:3066\:304b\:3089\:5341\:6570\:79d2\:306a\:306b\:3082\:51fa\:306a\:3044\:4e3b\:56e0)\:3002\:5225\:540d\:8f9e\:66f8\:306f\:4e2d\:8eab\:306e\:30cf\:30c3\:30b7\:30e5\:3067\:7d22\:5f15\:3092\:4f5c\:308a\:76f4\:3059 *)
$kgNormKeyCache = <||>;
iKGNormKeyCached[s_String] := If[KeyExistsQ[$kgNormKeyCache, s], $kgNormKeyCache[s],
  If[Length[$kgNormKeyCache] > 20000, $kgNormKeyCache = <||>];
  $kgNormKeyCache[s] = iKGNormalizeKey[s]];
$kgAliasIndex = <|"Hash" -> None, "Index" -> <||>|>;
iKGAliasIndex[] := With[{al = SourceVault`$SourceVaultKGDomainAliases},
  With[{h = Hash[al]},
    If[$kgAliasIndex["Hash"] =!= h,
      (* \:540c\:3058\:6b63\:898f\:5f62\:306e\:30ad\:30fc\:304c\:8907\:6570\:3042\:308c\:3070\:5148\:306b\:66f8\:304b\:308c\:305f\:3082\:306e\:304c\:52dd\:3064 (\:65e7\:5b9f\:88c5\:306e SelectFirst \:3068\:540c\:3058) *)
      $kgAliasIndex = <|"Hash" -> h, "Index" -> If[AssociationQ[al],
        Association[Map[iKGNormKeyCached[#] -> al[#] &, Reverse[Select[Keys[al], StringQ]]]], <||>]|>];
    $kgAliasIndex["Index"]]];
iKGCanonicalDomain[d_String] := Lookup[iKGAliasIndex[], iKGNormKeyCached[d], StringTrim[d]];

iKGDomainMatchQ[nodeDomain_String, audienceDomain_String] := Module[
  {a = iKGNormKeyCached[iKGCanonicalDomain[nodeDomain]], b = iKGNormKeyCached[iKGCanonicalDomain[audienceDomain]]},
  a =!= "" && b =!= "" && (a === b || StringContainsQ[a, b] || StringContainsQ[b, a])];

(* \:95a2\:6570\:578b: \:66f4\:65b0\:3057\:305f\:8074\:304d\:624b\:9023\:60f3\:3092\:8fd4\:3059 (\:5f15\:6570\:306e\:66f8\:304d\:63db\:3048\:306f WL \:3067\:306f\:52b9\:304b\:306a\:3044) *)
iKGAudienceKnow[aud_Association, domain_String, level_] :=
  Module[{a = aud}, a["Knowledge"][domain] = Max[Lookup[a["Knowledge"], domain, 0.], level]; a];

iKGAudienceToken[aud_Association, tok_String] := Module[{t = StringTrim[tok], m, preset, a = aud},
  If[t === "", Return[a]];
  m = StringCases[t, StartOfString ~~ name__ ~~ ("=" | ":" | "\:ff1d") ~~ v__ ~~ EndOfString :>
    {StringTrim[name], Quiet @ Check[ToExpression[StringTrim[v]], $Failed]}, 1];
  If[m =!= {} && NumericQ[m[[1, 2]]],
    a["Knowledge"][iKGCanonicalDomain[m[[1, 1]]]] = Clip[N[m[[1, 2]]], {0., 1.}];
    Return[a]];
  preset = SelectFirst[Keys[SourceVault`$SourceVaultKGAudiencePresets], iKGNormalizeKey[#] === iKGNormalizeKey[t] &, None];
  If[preset =!= None,
    With[{p = SourceVault`$SourceVaultKGAudiencePresets[preset]},
      a["Presets"] = Append[a["Presets"], preset];
      a["Level"] = Max[a["Level"], p["Level"]];
      Do[a = iKGAudienceKnow[a, k, p["Knowledge"][k]], {k, Keys[p["Knowledge"]]}]];
    Return[a]];
  (* \:672a\:77e5\:306e\:8a9e\:306f\:300c\:305d\:306e\:9818\:57df\:306f\:77e5\:3063\:3066\:3044\:308b (0.7)\:300d\:3068\:3057\:3066\:6271\:3044\:3001Unknown \:306b\:3082\:8a18\:9332\:3059\:308b *)
  a = iKGAudienceKnow[a, iKGCanonicalDomain[t], 0.7];
  a["Unknown"] = Append[a["Unknown"], t];
  a];

iKGAudienceTokens[aud_Association, toks_List] := Fold[iKGAudienceToken[#1, iKGStr[#2]] &, aud, toks];

SourceVaultKGAudience[spec_] := Module[{aud, tokens, a, k},
  aud = <|"Level" -> 0., "Knowledge" -> <||>, "Presets" -> {}, "Language" -> "ja",
    "Description" -> "", "Unknown" -> {}|>;
  Which[
    spec === Automatic || spec === None || spec === Null, aud = iKGAudienceToken[aud, "\:4e00\:822c"],
    StringQ[spec], tokens = StringSplit[spec, {",", "\:3001", ";", "\n"}];
      aud = If[tokens === {}, iKGAudienceToken[aud, "\:4e00\:822c"], iKGAudienceTokens[aud, tokens]],
    ListQ[spec], Do[Which[StringQ[x], aud = iKGAudienceToken[aud, x],
        MatchQ[x, _Rule], aud["Knowledge"][iKGCanonicalDomain[iKGStr[First[x]]]] = iKGClip[Last[x], 0.7],
        True, Null], {x, spec}],
    iKGAssocQ[spec], a = KeyMap[ToString, iKGAssoc[spec]];
      aud = iKGAudienceTokens[aud, iKGStrList[Lookup[a, "Presets", {}]]];
      If[NumericQ[Lookup[a, "Level", None]], aud["Level"] = iKGClip[a["Level"], aud["Level"]]];
      k = Lookup[a, "Knowledge", <||>];
      If[iKGAssocQ[k], Do[aud["Knowledge"][iKGCanonicalDomain[iKGStr[d]]] = iKGClip[iKGAssoc[k][d], 0.5], {d, Keys[iKGAssoc[k]]}]];
      If[ListQ[k], aud = iKGAudienceTokens[aud, k]];
      If[StringQ[Lookup[a, "Language", None]], aud["Language"] = a["Language"]];
      If[StringQ[Lookup[a, "Description", None]], aud["Description"] = a["Description"]];
      If[StringQ[Lookup[a, "Audience", None]], aud = iKGAudienceTokens[aud, StringSplit[a["Audience"], {",", "\:3001"}]]],
    True, aud = iKGAudienceToken[aud, "\:4e00\:822c"]];
  If[aud["Presets"] === {} && aud["Knowledge"] === <||>, aud = iKGAudienceToken[aud, "\:4e00\:822c"]];
  aud];

iKGKnown[node_Association, aud_Association] := Module[{doms = Lookup[node, "Domains", {}], hits},
  hits = Flatten[Map[Function[d,
    Select[Keys[aud["Knowledge"]], iKGDomainMatchQ[d, #] &] /. k_String :> aud["Knowledge"][k]], doms]];
  hits = Select[hits, NumericQ];
  If[hits === {}, aud["Level"], Max[Append[hits, aud["Level"]]]]];

SourceVaultKGNeed[kg_Association, audSpec_] := Module[{aud = SourceVaultKGAudience[audSpec]},
  Association[(#["Id"] -> N[#["Difficulty"] - iKGKnown[#, aud]]) & /@ Lookup[kg, "Nodes", {}]]];

SourceVaultKGScores[kg_Association, audSpec_] := Module[{aud = SourceVaultKGAudience[audSpec], too = SourceVault`$SourceVaultKGTooHard},
  Association[Map[Function[n,
    Module[{known = iKGKnown[n, aud], need, rel, score, flags = {}},
      need = N[n["Difficulty"] - known];
      rel = If[n["Layer"] === "Paper", 1., Clip[need, {0., 1.}]];
      If[n["Layer"] =!= "Paper" && need <= 0., AppendTo[flags, "Assumed"]];
      score = n["Importance"] * rel;
      If[need > too, AppendTo[flags, "TooHard"]; score *= 0.5];
      n["Id"] -> <|"Need" -> need, "Known" -> known, "Score" -> score, "Flags" -> flags|>]],
    Lookup[kg, "Nodes", {}]]]];

(* ---------------- \:9806\:5e8f\:30b0\:30e9\:30d5\:3068\:7dda\:5f62\:62e1\:5f35 ---------------- *)

iKGEdgeStrength[e_Association] := e["Weight"] * e["Confidence"];

(* \:9589\:8def\:3092 1 \:3064\:898b\:3064\:3051\:308b (FindCycle \:304c\:4f7f\:3048\:306a\:3044\:3068\:304d\:306e\:4ee3\:308f\:308a): \:5f37\:9023\:7d50\:6210\:5206\:306e\:4e2d\:3092\:8fba\:306b\:6cbf\:3063\:3066\:6b69\:3051\:3070
   \:5fc5\:305a\:540c\:3058\:9802\:70b9\:306b\:623b\:308b\:3002\:81ea\:5df1\:30eb\:30fc\:30d7\:306f\:305d\:308c\:81ea\:4f53\:304c\:9589\:8def *)
iKGCycleBySCC[g_Graph] := Module[{loops, sccs, scc, adj, path, nx, p},
  loops = Select[EdgeList[g], #[[1]] === #[[2]] &];
  If[loops =!= {}, Return[{{First[loops]}}]];
  sccs = Select[ConnectedComponents[g], Length[#] > 1 &];
  If[sccs === {}, Return[{}]];
  scc = First[sccs];
  adj = GroupBy[Select[EdgeList[g], MemberQ[scc, #[[1]]] && MemberQ[scc, #[[2]]] &], First -> Last];
  path = {First[scc]};
  Do[
    nx = First[Lookup[adj, Last[path], {None}]];
    If[nx === None, Return[{}, Module]];
    If[MemberQ[path, nx],
      p = First[FirstPosition[path, nx]];
      Return[{DirectedEdge @@@ Partition[Append[path[[p ;;]], nx], 2, 1]}, Module]];
    AppendTo[path, nx],
    {Length[scc] + 1}];
  {}];

SourceVaultKGOrderGraph[kg_Association] := Module[
  {ids = Lookup[Lookup[kg, "Nodes", {}], "Id", {}], oedges, g, dropped = {}, cyc, worst, k = 0, pw, build},
  oedges = Select[Lookup[kg, "Edges", {}], TrueQ[#["Order"]] &];
  (* \:540c\:3058\:5411\:304d\:306e\:8fba\:304c\:8907\:6570\:3042\:308b (Contains \:3068 LeadsTo \:304c\:4e26\:3076\:7b49) \:3068\:91cd\:307f\:3064\:304d\:591a\:91cd\:30b0\:30e9\:30d5\:306b\:306a\:308a\:3001FindCycle \:304c
     \:8a55\:4fa1\:3055\:308c\:305a\:306b\:8fd4\:308b (15.0 \:5b9f\:6e2c)\:3002\:3059\:308b\:3068\:9589\:8def\:304c\:5207\:308c\:306a\:3044\:307e\:307e\:7dda\:5f62\:62e1\:5f35\:304c\:6b62\:307e\:308a\:3001\:8ad6\:6587\:672c\:4f53\:304c\:4e38\:3054\:3068
     \:9806\:5e8f\:6728\:304b\:3089\:843d\:3061\:305f (\:8a08\:7b97\:3068\:81ea\:713633: 166 \:30ce\:30fc\:30c9\:4e2d 89 \:304c\:5b64\:7acb\:3057\:300145 \:679a\:306e\:6307\:5b9a\:3067 23 \:679a\:3057\:304b\:51fa\:306a\:304b\:3063\:305f)\:3002
     \:30b0\:30e9\:30d5\:306f (From, To) \:3054\:3068\:306b 1 \:672c\:3001\:91cd\:307f\:306f\:305d\:306e\:6700\:5927\:3067\:7d44\:3080 *)
  pw[es_] := GroupBy[es, {#["From"], #["To"]} &, Max[iKGEdgeStrength /@ #] &];
  build[es_] := With[{w = pw[es]}, Graph[ids, DirectedEdge @@@ Keys[w], EdgeWeight -> Values[w]]];
  g = build[oedges];
  While[! AcyclicGraphQ[g] && k < Length[oedges],
    k++;
    cyc = Quiet @ Check[FindCycle[g, Infinity, 1], {}];
    If[! MatchQ[cyc, {{__DirectedEdge}, ___}], cyc = iKGCycleBySCC[g]];
    If[cyc === {}, Break[]];
    cyc = First[cyc];
    With[{w = pw[oedges]},
      worst = First[MinimalBy[cyc, Lookup[w, Key[{#[[1]], #[[2]]}], 1.] &]]];
    AppendTo[dropped, <|"From" -> worst[[1]], "To" -> worst[[2]], "Reason" -> "Cycle"|>];
    oedges = DeleteCases[oedges, e_ /; e["From"] === worst[[1]] && e["To"] === worst[[2]]];
    g = build[oedges]];
  <|"Graph" -> g, "Dropped" -> dropped, "OrderEdges" -> oedges|>];

(* \:95a2\:9023\:5ea6\:884c\:5217 (\:7121\:5411): \:4efb\:610f\:306e\:8fba\:306e Weight \:3092\:4e21\:5411\:304d\:306b *)
iKGRelatedness[kg_Association] := Module[{r = <||>},
  Do[r[{e["From"], e["To"]}] = Max[Lookup[r, Key[{e["From"], e["To"]}], 0.], e["Weight"]];
     r[{e["To"], e["From"]}] = Max[Lookup[r, Key[{e["To"], e["From"]}], 0.], e["Weight"]],
    {e, Lookup[kg, "Edges", {}]}];
  r];

iKGPriority["Source", n_, ___] := {If[NumericQ[n["Order"]], n["Order"], Infinity], -n["Importance"], n["Id"]};
iKGPriority["Importance", n_, ___] := {-n["Importance"], If[NumericQ[n["Order"]], n["Order"], Infinity], n["Id"]};
iKGPriority["Difficulty", n_, ___] := {n["Difficulty"], If[NumericQ[n["Order"]], n["Order"], Infinity], n["Id"]};
iKGPriority["Coherent", n_, placed_, last_, rel_] := {
  -(2. * Lookup[rel, Key[{last, n["Id"]}], 0.] + Total[Lookup[rel, Key[{#, n["Id"]}], 0.] & /@ placed]),
  If[NumericQ[n["Order"]], n["Order"], Infinity], -n["Importance"], n["Id"]};
iKGPriority[_, n_, rest___] := iKGPriority["Source", n, rest];

SourceVaultKGLinearOrder[kg_Association, strategy_String : "Source"] :=
  iKGLinearOrder[kg, SourceVaultKGOrderGraph[kg], strategy]["Order"];

iKGEffectiveOrders[index_Association, succ_Association] := Module[{ix = index, changed = True, k = 0, vals},
  While[changed && k < Length[ix],
    changed = False; k++;
    Do[If[! NumericQ[ix[id]["Order"]],
        vals = Select[Lookup[ix[#], "Order", None] & /@ Lookup[succ, id, {}], NumericQ];
        If[vals =!= {}, ix[id]["Order"] = Min[vals] - 0.5; changed = True]],
      {id, Keys[ix]}]];
  ix];

iKGLinearOrder[kg_Association, og_Association, strategy_String] := Module[
  {index = iKGNodeIndex[kg], root = Lookup[kg, "Root", None], oedges = og["OrderEdges"],
   indeg, succ, ready, order = {}, placed = {}, last = None, rel, pick, dropped = og["Dropped"], ids},
  ids = Keys[index];
  (* Root \:304c\:6700\:521d\:306b\:6765\:308b\:3088\:3046\:306b Root \:3078\:306e\:9806\:5e8f\:8fba\:306f\:843d\:3068\:3059 (\:8a3a\:65ad\:306b\:8a18\:9332) *)
  If[StringQ[root],
    With[{into = Select[oedges, #["To"] === root &]},
      If[into =!= {},
        dropped = Join[dropped, <|"From" -> #["From"], "To" -> #["To"], "Reason" -> "RootIncoming"|> & /@ into];
        oedges = DeleteCases[oedges, e_ /; e["To"] === root]]]];
  indeg = AssociationMap[0 &, ids];
  succ = AssociationMap[{} &, ids];
  Do[indeg[e["To"]] += 1; succ[e["From"]] = Append[succ[e["From"]], e["To"]], {e, oedges}];
  (* \:51fa\:73fe\:9806 (Order) \:306e\:7121\:3044\:30ce\:30fc\:30c9 (LLM \:304c\:5f8c\:304b\:3089\:8db3\:3057\:305f\:524d\:63d0\:77e5\:8b58\:306a\:3069) \:306f\:300c\:6700\:521d\:306b\:5fc5\:8981\:3068\:3055\:308c\:308b
     \:30ce\:30fc\:30c9\:306e\:76f4\:524d\:300d\:306b\:7f6e\:304f (just-in-time)\:3002\:672b\:5c3e\:306b\:6c88\:3081\:308b\:3068\:4f9d\:5b58\:30ce\:30fc\:30c9\:307e\:3067\:5f15\:304d\:305a\:3089\:308c\:308b *)
  index = iKGEffectiveOrders[index, succ];
  rel = If[strategy === "Coherent", iKGRelatedness[kg], <||>];
  ready = Select[ids, indeg[#] === 0 &];
  While[ready =!= {},
    pick = If[StringQ[root] && MemberQ[ready, root] && order === {}, root,
      First[SortBy[ready, iKGPriority[strategy, index[#], placed, last, rel] &]]];
    AppendTo[order, pick]; AppendTo[placed, pick]; last = pick;
    ready = DeleteCases[ready, pick];
    Do[indeg[s] -= 1; If[indeg[s] === 0, AppendTo[ready, s]], {s, succ[pick]}]];
  <|"Order" -> order, "Dropped" -> dropped, "Unplaced" -> Complement[ids, order]|>];

(* ---------------- \:6700\:5c0f\:5168\:57df\:9806\:5e8f\:6728 (\:53f3\:80cc\:9aa8\:8caa\:6b32 = \:7dda\:5f62\:62e1\:5f35\:306e\:968e\:5c64\:5206\:5272) ----------------
   \:5b50\:306f\:89aa\:3088\:308a\:5f8c\:306b\:3001\:90e8\:5206\:6728\:306f\:9023\:7d9a\:533a\:9593\:306b\:7f6e\:304b\:308c\:308b\:3002\:524d\:9806\:8d70\:67fb = \:7dda\:5f62\:62e1\:5f35\:305d\:306e\:3082\:306e\:3002 *)

iKGAffinityTable[kg_Association] := Module[{t = <||>, spec},
  Do[
    spec = SourceVault`$SourceVaultKGEdgeKinds[e["EdgeKind"]];
    Switch[spec["Parent"],
      "From", t[{e["From"], e["To"]}] = Max[Lookup[t, Key[{e["From"], e["To"]}], 0.], e["Weight"] * spec["Affinity"]],
      "To", t[{e["To"], e["From"]}] = Max[Lookup[t, Key[{e["To"], e["From"]}], 0.], e["Weight"] * spec["Affinity"]],
      "Either", t[{e["From"], e["To"]}] = Max[Lookup[t, Key[{e["From"], e["To"]}], 0.], e["Weight"] * spec["Affinity"]];
        t[{e["To"], e["From"]}] = Max[Lookup[t, Key[{e["To"], e["From"]}], 0.], e["Weight"] * spec["Affinity"]],
      _, Null],
    {e, Lookup[kg, "Edges", {}]}];
  t];

Options[SourceVaultKGOrderedTree] = {"Strategy" -> "Source", "MaxDepth" -> Automatic, "DepthPenalty" -> 0.02, "UseToc" -> True};
SourceVaultKGOrderedTree[kg_Association, OptionsPattern[]] := Module[
  {og, lin, order, root, aff, succ, stack, parent = <||>, children = <||>, depth = <||>, score = 0.,
   maxDepth = Replace[OptionValue["MaxDepth"], Except[_Integer] :> 3 + iKGClusterLevels[kg]],
   pen = OptionValue["DepthPenalty"], strategy = OptionValue["Strategy"], best, cand},
  (* v1.46: \:76ee\:6b21\:304c\:3042\:308c\:3070\:3001\:305d\:308c\:304c\:9806\:5e8f\:6728 (\:76ee\:6b21\:306f LLM \:304c\:30dc\:30c8\:30e0\:30a2\:30c3\:30d7\:306b\:4f5c\:308a\:3001\:4f9d\:5b58\:3067\:4e26\:3079\:66ff\:3048\:6e08\:307f) *)
  If[TrueQ[OptionValue["UseToc"]] && SourceVaultKGTocQ[kg], Return[SourceVaultKGTocTree[kg]]];
  og = SourceVaultKGOrderGraph[kg];
  lin = iKGLinearOrder[kg, og, strategy];
  order = lin["Order"];
  If[order === {}, Return[Failure["EmptyGraph", <|"MessageTemplate" -> "no nodes to order"|>]]];
  root = First[order];
  aff = iKGAffinityTable[kg];
  (* \:524d\:63d0\:30ce\:30fc\:30c9\:306f\:3001\:305d\:308c\:3092\:5fc5\:8981\:3068\:3059\:308b\:30ce\:30fc\:30c9\:306e\:7bc0\:306e\:4e2d\:306b\:7f6e\:304f: x -> w \:306e\:9806\:5e8f\:8fba\:304c\:3042\:308c\:3070
     w \:306b\:5bfe\:3059\:308b\:89aa\:548c\:5ea6\:3092 (0.8 \:500d\:3067) x \:306b\:3082\:7d99\:627f\:3059\:308b *)
  succ = <||>;
  Do[succ[e["From"]] = Append[Lookup[succ, e["From"], {}], e["To"]], {e, og["OrderEdges"]}];
  stack = {root}; children[root] = {}; depth[root] = 0;
  Do[
    cand = Map[Function[y, {y,
      Max[Prepend[0.8 * Lookup[aff, Key[{y, #}], 0.] & /@ Lookup[succ, x, {}], Lookup[aff, Key[{y, x}], 0.]]] -
        pen * depth[y]}], stack];
    (* \:89aa\:5019\:88dc\:306f\:53f3\:80cc\:9aa8\:4e0a\:306e\:30ce\:30fc\:30c9\:3002\:6df1\:3055\:4e0a\:9650\:3092\:8d85\:3048\:308b\:89aa\:306f\:8a31\:3055\:306a\:3044 *)
    cand = Select[cand, depth[#[[1]]] + 1 <= maxDepth &];
    best = If[cand === {}, {root, 0.}, First[MaximalBy[cand, Last]]];
    (* \:89aa\:548c\:5ea6\:304c\:7121\:3044 (0) \:3068\:304d\:306f\:6700\:4e0a\:4f4d (root) \:306b\:4ed8\:3051\:3066\:65b0\:3057\:3044\:90e8\:3092\:59cb\:3081\:308b *)
    If[Last[best] <= 0., best = {root, 0.}];
    parent[x] = First[best];
    children[First[best]] = Append[Lookup[children, First[best], {}], x];
    children[x] = {};
    depth[x] = depth[First[best]] + 1;
    score += Max[Last[best], 0.];
    stack = Append[Take[stack, First[FirstPosition[stack, First[best]]]], x],
    {x, Rest[order]}];
  <|"ObjectClass" -> "SourceVaultKGOrderedTree", "GraphId" -> Lookup[kg, "GraphId", ""],
    "Strategy" -> strategy, "Root" -> root, "Order" -> order, "Parent" -> parent,
    "Children" -> children, "Depth" -> depth, "Score" -> score,
    "Diagnostics" -> <|"Dropped" -> lin["Dropped"], "Unplaced" -> lin["Unplaced"],
      "RootMismatch" -> If[StringQ[Lookup[kg, "Root", None]] && root =!= kg["Root"], kg["Root"], None]|>|>];

Options[SourceVaultKGOrderedTrees] = {"Strategies" -> {"Source", "Coherent", "Importance", "Difficulty"},
  "MaxDepth" -> Automatic, "DepthPenalty" -> 0.02};
SourceVaultKGOrderedTrees[kg_Association, OptionsPattern[]] := ReverseSortBy[
  Select[Map[SourceVaultKGOrderedTree[kg, "Strategy" -> #, "MaxDepth" -> OptionValue["MaxDepth"],
      "DepthPenalty" -> OptionValue["DepthPenalty"]] &, OptionValue["Strategies"]], AssociationQ],
  #["Score"] &];

(* ---------------- v1.44: \:6b21\:6570\:306e\:4e0a\:9650 (\:968e\:5c64\:5316) ----------------
   \:30b9\:30e9\:30a4\:30c9\:306f\:9806\:5e8f\:6728\:3092\:524d\:304b\:3089\:305f\:3069\:3063\:3066\:4f5c\:308b\:3002\:3069\:306e\:30ce\:30fc\:30c9\:3082\:5b50 (\:9806\:5e8f\:6728\:3067\:76f4\:4e0b\:3001\:96a0\:3059\:30fb\:975e\:516c\:958b\:3092\:9664\:304f) \:304c "MaxDegree" (\:65e2\:5b9a 5)
   \:4ee5\:4e0b\:3067\:306a\:3044\:3068\:3001\:76ee\:6b21\:3084\:7bc0\:306e\:9053\:6a19\:306e\:679a\:304c 1 \:679a\:3067\:898b\:6e21\:305b\:306a\:3044 (\:8a08\:7b97\:3068\:81ea\:713634: \:6839\:306e\:5b50 17 \:2192 \:5168\:4f53\:306e\:6d41\:308c\:304c\:300c\:2026\:300d\:3067\:5207\:308c\:305f)\:3002
   \:8d85\:3048\:308b\:30ce\:30fc\:30c9\:306e\:5b50\:3092\:3001\:6728\:306e\:9806\:306e\:307e\:307e\:9023\:7d9a\:3057\:305f\:300c\:307e\:3068\:307e\:308a\:300d(Section\:3001"Cluster" -> True) \:306b\:5206\:3051\:3066\:6bb5\:3092\:8db3\:3059\:3002\:6df1\:3044\:65b9\:304b\:3089\:3001
   \:5168\:90e8\:304c\:4e0a\:9650\:4ee5\:4e0b\:306b\:306a\:308b\:307e\:3067\:7e70\:308a\:8fd4\:3059 (\:5b50\:304c\:4e0a\:9650\:306e 2 \:4e57\:3092\:8d85\:3048\:308b\:3068\:304d\:306f 2 \:6bb5\:4ee5\:4e0a)\:3002\:5206\:3051\:65b9 ("Groups") \:3068\:984c\:76ee\:30fb\:8981\:7d04 ("Info") \:306f
   LLM \:306e\:63d0\:6848\:3092\:4f7f\:3048\:308b\:304c\:3001\:6728\:306e\:9806\:3067\:9023\:7d9a\:30fb\:6f0f\:308c\:306a\:304f\:30fb\:5404\:307e\:3068\:307e\:308a\:304c\:4e0a\:9650\:4ee5\:4e0b\:3067\:306a\:3051\:308c\:3070\:6368\:3066\:3066\:7b49\:5206\:3059\:308b ("Rejected")\:3002 *)
iKGVisibleQ[index_Association, id_] := With[{n = Lookup[index, id, <||>]},
  ! TrueQ[Lookup[n, "Hidden", False]] && Replace[Lookup[n, "PrivacyLevel", 0.], Except[_?NumericQ] -> 0.] <= 0.5];

(* \:307e\:3068\:307e\:308a\:306e\:6bb5\:306e\:6570 (Contains \:306e\:89aa\:3092\:305f\:3069\:3063\:3066\:6570\:3048\:308b)\:3002\:9806\:5e8f\:6728\:306e\:6df1\:3055\:306e\:4e0a\:9650\:306f\:3053\:306e\:5206\:3060\:3051\:6df1\:304f\:3059\:308b *)
iKGClusterLevels[kg_Association] := Module[{index = iKGNodeIndex[kg], par = <||>, lv},
  If[! AnyTrue[Lookup[kg, "Nodes", {}], TrueQ[Lookup[#, "Cluster", False]] &], Return[0]];
  Do[If[e["EdgeKind"] === "Contains" && ! KeyExistsQ[par, e["To"]], par[e["To"]] = e["From"]], {e, Lookup[kg, "Edges", {}]}];
  lv[id_] := Module[{x = id, c = 0, k = 0},
    While[KeyExistsQ[par, x] && k < 60, x = par[x]; k++;
      If[TrueQ[Lookup[Lookup[index, x, <||>], "Cluster", False]], c++]];
    c];
  Max[Prepend[lv /@ Keys[par], 0]]];

Options[SourceVaultKGOverDegree] = {"Tree" -> Automatic, "Strategy" -> "Source"};
SourceVaultKGOverDegree[kg_Association, d_Integer, OptionsPattern[]] := Module[{tree = OptionValue["Tree"], index = iKGNodeIndex[kg]},
  If[tree === Automatic, tree = SourceVaultKGOrderedTree[kg, "Strategy" -> OptionValue["Strategy"]]];
  If[! AssociationQ[tree], Return[{}]];
  Select[Map[Function[x, With[{kids = Select[Lookup[tree["Children"], x, {}], iKGVisibleQ[index, #] &]},
      <|"Node" -> x, "Children" -> kids, "Degree" -> Length[kids], "Depth" -> Lookup[tree["Depth"], x, 0]|>]],
    tree["Order"]], #["Degree"] > d &]];

iKGEqualGroups[kids_List, d_Integer] := Module[{k = Length[kids], m, base, extra},
  m = Ceiling[k / d]; base = Quotient[k, m]; extra = Mod[k, m];
  TakeList[kids, Join[ConstantArray[base + 1, extra], ConstantArray[base, m - extra]]]];
iKGValidGroupingQ[g_, kids_List, d_Integer] := ListQ[g] && Length[g] >= 2 &&
  AllTrue[g, ListQ[#] && # =!= {} && Length[#] <= d && AllTrue[#, StringQ] &] && Flatten[g] === kids;

iKGShort[s_String, k_Integer] := If[StringLength[s] > k, StringTake[s, k] <> "\[Ellipsis]", s];
iKGClusterLabel[index_Association, grp_List, lang_String] := With[
  {a = iKGShort[SourceVaultKGText[index[First[grp]], "Label", lang], 18], b = iKGShort[SourceVaultKGText[index[Last[grp]], "Label", lang], 18]},
  a <> If[lang === "ja", " \:301c ", " - "] <> b];

iKGApplyGroups[g_Association, p_String, groups_List, infos_List, lang_String] := Module[
  {index = iKGNodeIndex[g], nodes = Lookup[g, "Nodes", {}], edges = Lookup[g, "Edges", {}], ids, newIds = {},
   rootQ = (p === Lookup[g, "Root", None])},
  ids = Lookup[nodes, "Id", {}];
  Do[With[{grp = groups[[i]], inf = If[i <= Length[infos] && AssociationQ[infos[[i]]], infos[[i]], <||>]},
      If[Length[grp] >= 2,
        Module[{cid, n = 1, ords, imp, lab},
          While[MemberQ[ids, "grp_" <> p <> "_" <> ToString[n]], n++];
          cid = "grp_" <> p <> "_" <> ToString[n]; AppendTo[ids, cid];
          ords = Select[Lookup[Lookup[index, #, <||>], "Order", None] & /@ grp, NumericQ];
          imp = Max[Prepend[Select[Lookup[Lookup[index, #, <||>], "Importance", 0.5] & /@ grp, NumericQ], 0.]];
          lab = With[{l = Lookup[inf, "Label", ""]}, If[StringQ[l] && StringTrim[l] =!= "", StringTrim[l], iKGClusterLabel[index, grp, lang]]];
          AppendTo[nodes, Join[<|"Id" -> cid, "Kind" -> "Section", "Label" -> lab,
            "Summary" -> With[{s = Lookup[inf, "Summary", ""]}, If[StringQ[s], StringTrim[s], ""]],
            "Gist" -> With[{s = Lookup[inf, "Gist", ""]}, If[StringQ[s], StringTrim[s], ""]], "Points" -> {},
            "Importance" -> If[rootQ, Max[0.5, imp], 0.8 * imp], "Difficulty" -> 0.4, "Layer" -> "Paper", "Cluster" -> True,
            "Source" -> <|"Kind" -> "Cluster", "Parent" -> p|>|>,
            If[ords =!= {}, <|"Order" -> Min[ords] - 0.001|>, <||>]]];
          edges = Select[edges, ! (#["EdgeKind"] === "Contains" && #["From"] === p && MemberQ[grp, #["To"]]) &];
          edges = Join[edges, {<|"From" -> p, "To" -> cid, "EdgeKind" -> "Contains", "Weight" -> 1.|>},
            Map[<|"From" -> cid, "To" -> #, "EdgeKind" -> "Contains", "Weight" -> 1.|> &, grp]];
          AppendTo[newIds, cid]]]],
    {i, Length[groups]}];
  {SourceVaultKGValidate[Join[g, <|"Nodes" -> nodes, "Edges" -> edges|>]], newIds}];

Options[SourceVaultKGBalance] = {"MaxDegree" -> 5, "Strategy" -> "Source", "Groups" -> <||>, "Info" -> <||>,
  "MaxRounds" -> 6, "Language" -> Automatic};
SourceVaultKGBalance[kg_Association, OptionsPattern[]] := Module[
  {d = OptionValue["MaxDegree"], g = kg, tree, over, added = {}, rejected = {}, used = {}, rounds = 0, prev = None,
   proposals = Replace[OptionValue["Groups"], Except[_Association] -> <||>],
   info = Replace[OptionValue["Info"], Except[_Association] -> <||>], lang, final},
  If[! (IntegerQ[d] && d >= 2), Return[Failure["BadMaxDegree", <|"MessageTemplate" -> "MaxDegree must be an integer >= 2"|>]]];
  lang = Replace[OptionValue["Language"], Automatic -> Lookup[kg, "Language", "ja"]];
  While[rounds < OptionValue["MaxRounds"],
    tree = SourceVaultKGOrderedTree[g, "Strategy" -> OptionValue["Strategy"]];
    If[! AssociationQ[tree], Break[]];
    over = SourceVaultKGOverDegree[g, d, "Tree" -> tree];
    (* \:307e\:3068\:307e\:308a\:3092\:8db3\:3057\:3066\:3082\:6728\:304c\:5909\:308f\:3089\:306a\:3044 (\:89aa\:548c\:5ea6\:3084\:9806\:5e8f\:306e\:90fd\:5408) \:306a\:3089\:6253\:3061\:5207\:308b *)
    If[over === {} || over === prev, Break[]];
    prev = over; rounds++;
    Do[Module[{p = o["Node"], kids = o["Children"], prop, groups, res},
        prop = If[MemberQ[used, p], None, Lookup[proposals, p, None]];
        groups = If[iKGValidGroupingQ[prop, kids, d], prop,
          If[prop =!= None, AppendTo[rejected, p]]; iKGEqualGroups[kids, d]];
        AppendTo[used, p];
        res = iKGApplyGroups[g, p, groups, If[groups === prop, Replace[Lookup[info, p, {}], Except[_List] -> {}], {}], lang];
        If[AssociationQ[res[[1]]], g = res[[1]]; added = Join[added, res[[2]]]]],
      {o, SortBy[over, -#["Depth"] &]}]];
  final = SourceVaultKGOverDegree[g, d, "Strategy" -> OptionValue["Strategy"]];
  <|"KG" -> g, "Added" -> added, "Rejected" -> DeleteDuplicates[rejected], "Unresolved" -> Lookup[final, "Node", {}],
    "Rounds" -> rounds, "MaxDegree" -> d|>];

(* \:76ee\:6b21\:306e\:884c: \:90e8\:306e\:4e00\:884c\:8981\:7d04 (Gist\:3002\:305d\:306e\:8a00\:8a9e\:306e\:3082\:306e\:304c\:3042\:308b\:3068\:304d)\:3001\:7121\:3051\:308c\:3070\:984c\:76ee *)
iKGHasGistQ[n_Association, lang_, primary_] := SourceVaultKGText[n, "Gist", lang] =!= "" && iKGHasLanguageQ[Lookup[n, "Gist", ""], lang, primary];
iKGHasGistQ[___] := False;
iKGPartGist[n_, label_, lang_, primary_] := If[iKGHasGistQ[n, lang, primary], SourceVaultKGText[n, "Gist", lang], label];

(* ---------------- v1.46: \:76ee\:6b21 (Toc) ----------------
   \:30b9\:30e9\:30a4\:30c9\:306f\:300c\:76ee\:6b21\:306e\:6728\:300d\:3092\:524d\:304b\:3089\:305f\:3069\:3063\:3066\:4f5c\:308b\:3002\:76ee\:6b21\:306f\:30dc\:30c8\:30e0\:30a2\:30c3\:30d7\:306b\:4f5c\:308b: \:5185\:5bb9\:306e\:30ce\:30fc\:30c9 (\:8449) \:3092\:66f8\:7c4d\:306e\:7bc0\:306e\:3088\:3046\:306b\:307e\:3068\:3081\:3001
   \:7bc0\:3092\:7ae0\:306b\:307e\:3068\:3081\:308b (\:5404\:6bb5\:306e\:5144\:5f1f\:306f\:7b87\:6761\:66f8\:304d\:306b\:4e26\:3079\:305f\:3068\:304d\:540c\:3058\:30ec\:30d9\:30eb\:306e\:8a71\:3068\:3057\:3066\:4e26\:7acb\:3059\:308b\:3002SlideWorkflow \:306e LLM \:304c\:4f5c\:308b)\:3002
   \:305d\:306e\:3042\:3068\:3067\:5144\:5f1f\:306e\:9806\:3092\:3001\:7528\:8a9e\:306e\:5b9a\:7fa9\:3084\:524d\:63d0 (Prerequisite / Derives) \:304c\:5148\:306b\:6765\:308b\:3088\:3046\:5165\:308c\:66ff\:3048\:308b\:3002
   kg["Toc"] = <|"Root", "Children" -> <|\:89aa -> {\:5b50..}|>, "MaxDegree", "Omitted", "Known" (\:4f5c\:3063\:305f\:3068\:304d\:306b\:3042\:3063\:305f\:30ce\:30fc\:30c9),
   "Method", "BuiltAtUTC", "Violations"|>\:3002\:76ee\:6b21\:306e\:7bc0\:306f "Toc" -> True \:306e Section \:30ce\:30fc\:30c9 (Label / Gist / Summary / Importance /
   Include = Must | Optional)\:3002\:8cc7\:6599\:306e Contains (\:6587\:66f8\:306e\:69cb\:9020) \:306f\:305d\:306e\:307e\:307e\:6b8b\:3059\:3002 *)
SourceVaultKGTocQ[kg_Association] := AssociationQ[Lookup[kg, "Toc", None]] && AssociationQ[Lookup[kg["Toc"], "Children", None]];
SourceVaultKGTocQ[_] := False;

iKGTocChildren[kg_Association] := Association[KeyValueMap[ToString[#1] -> Select[iKGList[#2], StringQ] &, kg["Toc"]["Children"]]];

(* \:76ee\:6b21\:306e\:6728 (\:9806\:5e8f\:6728\:3068\:540c\:3058\:5f62)\:3002\:76ee\:6b21\:3092\:4f5c\:3063\:305f\:3042\:3068\:306b\:8db3\:3055\:308c\:305f\:30ce\:30fc\:30c9 (\:8abf\:6574\:306e\:679a\:3001\:5468\:8fba\:77e5\:8b58) \:306f\:3001\:524d\:306e\:679a (Precedes \:306e\:5143) \:306e\:5f8c\:308d \:2192
   Contains \:306e\:89aa\:306e\:672b\:5c3e \:2192 \:524d\:63d0\:5148 (Prerequisite \:306e\:5148) \:306e\:524d \:2192 \:6839\:306e\:672b\:5c3e\:3001\:306e\:9806\:3067\:7f6e\:304d\:5834\:6240\:3092\:63a2\:3059 *)
SourceVaultKGTocTree[kg_Association] := Module[
  {index = iKGNodeIndex[kg], toc = kg["Toc"], root, ch, seen = <||>, children = <||>, parentOf = <||>, parent = <||>,
   depth = <||>, order = {}, known, omitted, newIds, edges = Lookup[kg, "Edges", {}], visit, pre, cparent},
  root = With[{r = Lookup[toc, "Root", Lookup[kg, "Root", None]]}, If[StringQ[r] && KeyExistsQ[index, r], r, Lookup[kg, "Root", None]]];
  ch = iKGTocChildren[kg];
  known = Select[iKGList[Lookup[toc, "Known", {}]], StringQ];
  omitted = Select[iKGList[Lookup[toc, "Omitted", {}]], StringQ];
  visit[x_] := (seen[x] = True;
    children[x] = Select[Lookup[ch, x, {}], KeyExistsQ[index, #] && ! KeyExistsQ[seen, #] && (seen[#] = True; True) &];
    Do[parentOf[c] = x, {c, children[x]}];
    Scan[visit, children[x]]);
  visit[root];
  newIds = Select[SortBy[Lookup[Lookup[kg, "Nodes", {}], "Id", {}],
      {Replace[Lookup[index[#], "Order", None], Except[_?NumericQ] -> 10.^6] &, # &}],
    ! KeyExistsQ[seen, #] && ! MemberQ[known, #] && ! MemberQ[omitted, #] && ! TrueQ[Lookup[index[#], "Hidden", False]] &];
  cparent = Association[Map[#["To"] -> #["From"] &, Reverse[Select[edges, #["EdgeKind"] === "Contains" &]]]];
  Do[Module[{x = nid, a, w, p, k},
      a = SelectFirst[edges, #["To"] === x && #["EdgeKind"] === "Precedes" && KeyExistsQ[seen, #["From"]] && #["From"] =!= root &, None];
      w = SelectFirst[edges, #["From"] === x && MemberQ[{"Prerequisite", "Derives"}, #["EdgeKind"]] && KeyExistsQ[seen, #["To"]] && #["To"] =!= root &, None];
      Which[
        a =!= None,
          p = parentOf[a["From"]]; k = FirstPosition[children[p], a["From"]][[1]]; children[p] = Insert[children[p], x, k + 1],
        KeyExistsQ[cparent, x] && KeyExistsQ[seen, cparent[x]],
          p = cparent[x]; children[p] = Append[children[p], x],
        w =!= None,
          p = parentOf[w["To"]]; k = FirstPosition[children[p], w["To"]][[1]]; children[p] = Insert[children[p], x, k],
        True,
          p = root; children[p] = Append[children[p], x]];
      seen[x] = True; parentOf[x] = p; children[x] = {}],
    {nid, newIds}];
  pre[x_, d_] := (AppendTo[order, x]; depth[x] = d; Do[parent[c] = x; pre[c, d + 1], {c, Lookup[children, x, {}]}]);
  pre[root, 0];
  <|"ObjectClass" -> "SourceVaultKGOrderedTree", "GraphId" -> Lookup[kg, "GraphId", ""], "Strategy" -> "Toc", "Root" -> root,
    "Order" -> order, "Parent" -> parent, "Children" -> Association[Map[# -> Lookup[children, #, {}] &, order]], "Depth" -> depth,
    "Score" -> 0., "Diagnostics" -> <|"Dropped" -> {}, "Unplaced" -> {}, "Inserted" -> newIds, "RootMismatch" -> None|>|>];

(* \:5144\:5f1f\:306e\:4e26\:3079\:66ff\:3048: \:5b50 a \:306e\:90e8\:5206\:6728\:306e\:30ce\:30fc\:30c9\:304c\:5b50 b \:306e\:90e8\:5206\:6728\:306e\:30ce\:30fc\:30c9\:306e\:524d\:63d0 (Prerequisite / Derives) \:306a\:3089 a \:3092 b \:3088\:308a\:524d\:306b\:3002
   \:5143\:306e\:9806 (\:8a71\:3059\:9806) \:3092\:3067\:304d\:308b\:3060\:3051\:4fdd\:3064\:5b89\:5b9a\:306a\:4f4d\:76f8\:6574\:5217\:3002\:9589\:8def\:306f\:5143\:306e\:9806\:306e\:307e\:307e\:6b8b\:3057\:3066\:8a18\:9332\:3059\:308b *)
iKGTocReorder[kg_Association, ch_Association] := Module[{hard, desc, out = ch, viol = {}},
  hard = Select[Lookup[kg, "Edges", {}], MemberQ[{"Prerequisite", "Derives"}, #["EdgeKind"]] &];
  desc[x_] := desc[x] = Prepend[Flatten[desc /@ Lookup[ch, x, {}]], x];
  Do[With[{ks = Lookup[ch, p, {}]},
      If[Length[ks] >= 2,
        Module[{subOf, rel = <||>, remaining, res = {}},
          subOf = Association[Flatten[MapIndexed[Function[{c, i}, Thread[desc[c] -> First[i]]], ks]]];
          Do[With[{a = Lookup[subOf, e["From"], 0], b = Lookup[subOf, e["To"], 0]},
              If[a > 0 && b > 0 && a =!= b, rel[{a, b}] = True]], {e, hard}];
          remaining = Range[Length[ks]];
          While[remaining =!= {},
            With[{free = Select[remaining, Function[j, ! AnyTrue[remaining, # =!= j && KeyExistsQ[rel, {#, j}] &]]]},
              If[free === {},
                AppendTo[viol, <|"Parent" -> p, "Cycle" -> ks[[remaining]]|>];
                AppendTo[res, First[remaining]]; remaining = Rest[remaining],
                AppendTo[res, First[free]]; remaining = DeleteCases[remaining, First[free]]]]];
          out[p] = ks[[res]]]]],
    {p, Keys[ch]}];
  {out, viol}];

(* \:76ee\:6b21\:3092 KG \:306b\:66f8\:304f\:3002children = <|\:89aa -> {\:5b50..}|> (\:6839\:304b\:3089)\:3002"Groups" = \:76ee\:6b21\:306e\:7bc0\:30ce\:30fc\:30c9 (\:65b0\:3057\:3044 Id \:306a\:3089\:8db3\:3059\:3001\:65e2\:5b58\:306a\:3089 Gist \:306a\:3069\:3092\:66f4\:65b0)\:3002
   d \:3092\:8d85\:3048\:308b\:5b50\:306e\:5217\:306f\:9023\:7d9a\:3057\:305f\:584a\:306b\:5206\:3051\:308b (\:984c\:76ee\:306f\:300c\:5148\:982d \:301c \:672b\:5c3e\:300d)\:3002\:305d\:306e\:3042\:3068\:4f9d\:5b58\:3067\:5144\:5f1f\:3092\:4e26\:3079\:66ff\:3048\:308b *)
Options[SourceVaultKGSetToc] = {"MaxDegree" -> 5, "Omitted" -> {}, "Method" -> "LLM", "Groups" -> {}, "Language" -> Automatic,
  "DropClusters" -> True};
SourceVaultKGSetToc[kg_Association, children_Association, OptionsPattern[]] := Module[
  {d = OptionValue["MaxDegree"], lang, g = kg, root = Lookup[kg, "Root", "root"], nodes, edges, index, ch, added = {}, split = {},
   viol, n = 0, over, newId, clusters, gs},
  If[! (IntegerQ[d] && d >= 2), d = 5];
  lang = Replace[OptionValue["Language"], Automatic -> Lookup[kg, "Language", "ja"]];
  nodes = Lookup[g, "Nodes", {}]; edges = Lookup[g, "Edges", {}];
  (* \:524d\:306e\:76ee\:6b21\:306e\:7bc0\:3092\:5916\:3059\:3002\:6a5f\:68b0\:7684\:306a\:307e\:3068\:307e\:308a (v1.44 \:306e Cluster) \:3082\:5916\:3057\:3066\:3001\:5b50\:3092\:5143\:306e\:89aa\:306e Contains \:306b\:623b\:3059 *)
  If[TrueQ[OptionValue["DropClusters"]],
    clusters = Select[nodes, TrueQ[Lookup[#, "Cluster", False]] &];
    Do[With[{c = cl["Id"], p = Lookup[Lookup[cl, "Source", <||>], "Parent", None]},
        If[StringQ[p], edges = Join[edges, Map[<|"From" -> p, "To" -> #, "EdgeKind" -> "Contains", "Weight" -> 1.|> &,
          Lookup[Select[edges, #["From"] === c && #["EdgeKind"] === "Contains" &], "To", {}]]]];
        edges = Select[edges, #["From"] =!= c && #["To"] =!= c &]],
      {cl, clusters}];
    nodes = Select[nodes, ! TrueQ[Lookup[#, "Cluster", False]] &]];
  nodes = Select[nodes, ! TrueQ[Lookup[#, "Toc", False]] &];
  index = Association[(#["Id"] -> #) & /@ nodes];
  gs = Select[iKGList[OptionValue["Groups"]], AssociationQ[#] && StringQ[Lookup[#, "Id", None]] &];
  Do[With[{id = gr["Id"], upd = Select[KeyTake[gr, {"Gist", "Summary", "Importance", "Include", "Label"}], # =!= None &]},
      If[KeyExistsQ[index, id],
        (* \:65e2\:5b58\:306e\:7bc0\:3092\:76ee\:6b21\:306b\:4f7f\:3046: \:984c\:76ee\:3068\:8981\:7d04\:306f\:65e2\:5b58\:3092\:512a\:5148\:3057\:3001\:4e00\:884c\:8981\:7d04\:30fb\:91cd\:8981\:5ea6\:30fb\:8981\:5426\:3092\:66f8\:304f *)
        index[id] = Join[index[id], KeyDrop[upd, Join[{"Label"}, If[SourceVaultKGText[index[id], "Summary"] =!= "", {"Summary"}, {}]]]],
        index[id] = Join[<|"Id" -> id, "Kind" -> "Section", "Layer" -> "Paper", "Toc" -> True, "Label" -> Lookup[gr, "Label", id],
          "Summary" -> "", "Gist" -> "", "Points" -> {}, "Importance" -> 0.6, "Difficulty" -> 0.4, "Include" -> "Optional"|>, upd];
        AppendTo[added, id]]],
    {gr, gs}];
  ch = Association[KeyValueMap[#1 -> Select[iKGList[#2], StringQ] &, children]];
  (* \:6b21\:6570: d \:3092\:8d85\:3048\:308b\:5b50\:306e\:5217\:3092\:9023\:7d9a\:3057\:305f\:584a\:306b\:307e\:3068\:3081\:308b (\:6bb5\:3092\:8db3\:3059) *)
  While[(over = Select[Keys[ch], Length[ch[#]] > d &]) =!= {} && n < 200,
    Do[With[{grps = iKGEqualGroups[ch[p], d]},
        ch[p] = Map[Function[grp, If[Length[grp] === 1, First[grp],
          n++; newId = "toc_" <> p <> "_" <> ToString[n];
          While[KeyExistsQ[index, newId], n++; newId = "toc_" <> p <> "_" <> ToString[n]];
          index[newId] = <|"Id" -> newId, "Kind" -> "Section", "Layer" -> "Paper", "Toc" -> True,
            "Label" -> iKGClusterLabel[index, grp, lang], "Summary" -> "", "Gist" -> "", "Points" -> {},
            "Importance" -> Max[Prepend[Select[Lookup[Lookup[index, #, <||>], "Importance", 0.5] & /@ grp, NumericQ], 0.5]],
            "Difficulty" -> 0.4, "Include" -> "Optional"|>;
          ch[newId] = grp; AppendTo[added, newId]; AppendTo[split, p]; newId]], grps]],
      {p, over}]];
  {ch, viol} = iKGTocReorder[<|"Edges" -> edges|>, ch];
  (* \:76ee\:6b21\:306e\:7bc0\:306e Order = \:5b50\:306e\:6700\:5c0f - 0.001 (KG \:56f3\:306e\:4e26\:3073\:3068\:56f3\:306e\:7d99\:627f\:306e\:8ddd\:96e2\:306b\:4f7f\:3046) *)
  Do[With[{os = Select[Lookup[Lookup[index, #, <||>], "Order", None] & /@ Lookup[ch, id, {}], NumericQ]},
      If[os =!= {}, index[id] = Append[index[id], "Order" -> Min[os] - 0.001]]],
    {id, Select[Keys[index], TrueQ[Lookup[index[#], "Toc", False]] &]}];
  g["Nodes"] = Values[index]; g["Edges"] = edges;
  g["Toc"] = <|"Version" -> 1, "Root" -> root, "Children" -> ch, "MaxDegree" -> d,
    "Omitted" -> Select[iKGList[OptionValue["Omitted"]], StringQ], "Known" -> Keys[index],
    "Method" -> ToString[OptionValue["Method"]], "BuiltAtUTC" -> iKGUTCNow[], "Violations" -> viol|>;
  <|"KG" -> SourceVaultKGValidate[g], "Added" -> added, "Split" -> DeleteDuplicates[split], "Violations" -> viol|>];

(* \:76ee\:6b21\:306e\:4e2d\:3067 id \:3092 after \:306e\:76f4\:5f8c\:3078\:52d5\:304b\:3059 (\:8abf\:6574\:306e After)\:3002after \:306e\:90e8\:5206\:6728\:306b\:5165\:308c\:308b\:3053\:3068\:306b\:306a\:308b\:52d5\:304d\:3068\:3001after \:304c\:76ee\:6b21\:306b\:7121\:3044\:3068\:304d\:306f\:4f55\:3082\:3057\:306a\:3044 *)
SourceVaultKGTocMove[kg_Association, id_String, after_String] := Module[{ch, p, k, desc, t},
  If[! SourceVaultKGTocQ[kg] || id === after, Return[kg]];
  ch = iKGTocChildren[kg];
  desc[x_, dep_] := If[dep > 64, {x}, Prepend[Flatten[desc[#, dep + 1] & /@ Lookup[ch, x, {}]], x]];
  If[MemberQ[desc[id, 0], after], Return[kg]];
  p = SelectFirst[Keys[ch], MemberQ[ch[#], after] &, None];
  If[p === None, Return[kg]];
  ch = Map[DeleteCases[#, id] &, ch];
  k = First[FirstPosition[ch[p], after]];
  ch[p] = Insert[ch[p], id, k + 1];
  t = kg["Toc"];
  t["Children"] = ch;
  t["Omitted"] = DeleteCases[Select[iKGList[Lookup[t, "Omitted", {}]], StringQ], id];
  t["Known"] = DeleteDuplicates[Append[Select[iKGList[Lookup[t, "Known", {}]], StringQ], id]];
  Append[kg, "Toc" -> t]];

(* LLM \:304c\:7121\:3044\:3068\:304d\:306e\:76ee\:6b21: \:8cc7\:6599\:306e\:69cb\:9020 (\:9806\:5e8f\:6728) \:3092\:305d\:306e\:307e\:307e\:76ee\:6b21\:306b\:3057\:3001\:6b21\:6570\:306e\:4e0a\:9650\:306f\:6a5f\:68b0\:7684\:306a\:307e\:3068\:307e\:308a\:3067\:5b88\:308b *)
Options[SourceVaultKGMechanicalToc] = {"MaxDegree" -> 5, "Strategy" -> "Source"};
SourceVaultKGMechanicalToc[kg_Association, OptionsPattern[]] := Module[{k0 = KeyDrop[kg, "Toc"], b, tree, ch, res},
  b = SourceVaultKGBalance[k0, "MaxDegree" -> OptionValue["MaxDegree"], "Strategy" -> OptionValue["Strategy"]];
  If[! AssociationQ[b], Return[b]];
  tree = SourceVaultKGOrderedTree[b["KG"], "Strategy" -> OptionValue["Strategy"]];
  If[! AssociationQ[tree], Return[tree]];
  ch = Select[tree["Children"], # =!= {} &];
  (* \:9806\:5e8f\:6728\:304c\:4e2d\:8eab\:3092\:5225\:306e\:89aa\:306b\:4ed8\:3051\:305f\:307e\:3068\:307e\:308a (\:5b50\:306e\:7121\:3044 Cluster) \:306f\:76ee\:6b21\:306b\:5165\:308c\:306a\:3044 *)
  With[{empty = Select[Keys[tree["Children"]], tree["Children"][#] === {} && TrueQ[Lookup[Lookup[iKGNodeIndex[b["KG"]], #, <||>], "Cluster", False]] &]},
    ch = Map[DeleteCases[#, Alternatives @@ empty] &, ch]];
  res = SourceVaultKGSetToc[b["KG"], ch, "MaxDegree" -> OptionValue["MaxDegree"], "Method" -> "Mechanical", "DropClusters" -> False];
  Append[res, "Preview" -> b["Added"]]];

(* \:76ee\:6b21\:304b\:3089\:306e\:8a08\:753b: \:76ee\:6b21\:306e\:6728\:3092\:4e0a\:304b\:3089\:958b\:304f\:3002\:3069\:306e\:7bc0\:3082\:300c\:6982\:8981\:306e 1 \:679a\:300d\:304b\:300c\:958b\:304f (\:5b50\:3092\:305d\:308c\:305e\:308c\:679a\:306b\:3059\:308b)\:300d\:306e\:3069\:3061\:3089\:304b\:3002
   \:958b\:304f\:306e\:306f\:6d45\:3044\:7bc0\:304b\:3089\:3001\:540c\:3058\:6df1\:3055\:306a\:3089\:91cd\:8981\:5ea6 (Include Must \:306f +1) \:306e\:9ad8\:3044\:9806\:306b\:3001\:679a\:6570\:306b\:53ce\:307e\:308b\:3068\:3053\:308d\:307e\:3067\:3002
   \:958b\:3044\:305f\:7bc0\:306e\:898b\:51fa\:3057\:306e\:679a (\:9053\:6a19) \:306f\:3001\:6839 (\:5168\:4f53\:306e\:6d41\:308c) \:3068\:6df1\:3055 "RoadmapDepth" (\:65e2\:5b9a 1 = \:90e8) \:307e\:3067\:3060\:3051\:3002\:305d\:308c\:3088\:308a\:6df1\:3044\:7bc0\:306f\:958b\:304f\:3068\:81ea\:5206\:306e\:679a\:3092\:5b50\:306b\:8b72\:308b
   (\:4f4d\:7f6e\:306f\:30d1\:30f3\:304f\:305a\:3067\:5206\:304b\:308b)\:3002\:53ce\:307e\:3089\:306a\:3044\:7bc0\:306f\:6982\:8981\:306e 1 \:679a\:3092\:6b8b\:3057\:3001\:305d\:306e\:5f8c\:308d\:306b\:5927\:4e8b\:306a\:5b50\:3060\:3051\:679a\:306b\:3059\:308b (Partial)\:30021 \:679a\:306a\:3089\:6839 (\:90e8\:306e\:4e00\:884c\:8981\:7d04) \:3060\:3051\:3002
   \:5fc5\:305a\:51fa\:3059 (Pinned) \:306f\:7956\:5148\:3092\:958b\:304b\:306a\:304f\:3066\:3082\:524d\:9806\:306e\:4f4d\:7f6e\:306b\:679a\:3068\:3057\:3066\:5165\:308b (\:679a\:6570\:3092\:8d85\:3048\:3066\:3082) *)
Options[SourceVaultKGTocPlan] = {"Slides" -> Automatic, "Seconds" -> Automatic, "SecondsPerSlide" -> 25., "Audience" -> Automatic,
  "ReleaseCeiling" -> 0.5, "RoadmapDepth" -> 1};
SourceVaultKGTocPlan[kg_Association, tree_Association, OptionsPattern[]] := Module[
  {index = iKGNodeIndex[kg], scores, root = tree["Root"], ceiling = OptionValue["ReleaseCeiling"], withheld, hidden, omitted,
   pinned, assumed, drop, alive, kids, order, pos, nSlides, seconds, sps = N[OptionValue["SecondsPerSlide"]], imp, anc, must,
   mode = <||>, shown = <||>, count, displayedQ, slideQ, internalQ, depth, h, c, new, delta, cands, remaining, forced, slides = {},
   internal, figOf, weights, total, secs, diag = {}, partial = {}, prio, figNode, figSub, folded},
  scores = SourceVaultKGScores[kg, OptionValue["Audience"]];
  withheld = Select[tree["Order"], Replace[Lookup[index[#], "PrivacyLevel", 0.], Except[_?NumericQ] -> 0.] > ceiling && # =!= root &];
  hidden = Select[tree["Order"], TrueQ[Lookup[index[#], "Hidden", False]] && # =!= root &];
  omitted = Select[tree["Order"], Lookup[index[#], "Include", ""] === "Omit" && # =!= root &];
  pinned = Select[tree["Order"], TrueQ[Lookup[index[#], "Pinned", False]] && # =!= root &];
  assumed = Select[tree["Order"], # =!= root && Lookup[tree["Children"], #, {}] === {} &&
    MemberQ[Lookup[Lookup[scores, #, <||>], "Flags", {}], "Assumed"] && ! MemberQ[pinned, #] &];
  drop = Association[Thread[Join[withheld, hidden, omitted, assumed] -> True]];
  alive[x_] := alive[x] = x === root || (! KeyExistsQ[drop, x] &&
    (Lookup[tree["Children"], x, {}] === {} || AnyTrue[tree["Children"][x], alive]));
  kids[x_] := kids[x] = Select[Lookup[tree["Children"], x, {}], alive];
  order = Select[tree["Order"], alive];
  pos = AssociationThread[order -> Range[Length[order]]];
  seconds = OptionValue["Seconds"]; nSlides = OptionValue["Slides"];
  If[! IntegerQ[nSlides] || nSlides < 1,
    nSlides = If[NumericQ[seconds] && seconds > 0, Max[1, Round[seconds / sps]], Length[order]]];
  h = Replace[OptionValue["RoadmapDepth"], Except[_Integer?NonNegative] -> 1];
  imp[x_] := Replace[Lookup[index[x], "Importance", 0.5], Except[_?NumericQ] -> 0.5];
  must = Select[order, Lookup[index[#], "Include", ""] === "Must" &];
  (* v1.49: \:56f3\:306e\:3042\:308b\:679a\:3092\:512a\:5148\:3059\:308b\:3002\:679a\:6570\:304c\:8db3\:308a\:306a\:3044\:3068\:304d\:3001\:5b50\:306b\:56f3\:3084\:8868\:304c\:3042\:308b\:7bc0\:304b\:3089\:958b\:304d\:3001\:4e00\:90e8\:3060\:3051\:958b\:304f\:7bc0\:3067\:3082\:56f3\:306e\:3042\:308b\:5b50\:3092\:6b8b\:3059
     (\:8a08\:7b97\:3068\:81ea\:713634: \:5fc5\:305a\:51fa\:3059\:679a\:3092 4 \:679a\:8db3\:3057\:305f\:3089\:3001\:56f3\:306e\:3042\:308b\:679a\:304c 5 \:679a\:3001\:9ed9\:3063\:3066\:6982\:8981\:306b\:7573\:307e\:308c\:305f) *)
  figNode[x_] := figNode[x] = AnyTrue[Replace[Lookup[index[x], "Assets", {}], Except[_List] -> {}],
    AssociationQ[#] && MemberQ[{"NotebookFigure", "PDFFigure", "PDFImage", "DeckSlide", "Image"}, Lookup[#, "Type", ""]] &];
  figSub[x_] := figSub[x] = figNode[x] || AnyTrue[kids[x], figSub];
  prio[x_] := imp[x] + If[MemberQ[must, x], 1., 0.] +
    If[kids[x] === {}, If[figNode[x], 0.3, 0.], 0.5 * N[Count[kids[x], _?figSub] / Length[kids[x]]]];
  depth[x_] := Lookup[tree["Depth"], x, 0];
  anc[x_] := Module[{p = Lookup[tree["Parent"], x, None], out = {}}, While[p =!= None, AppendTo[out, p]; p = Lookup[tree["Parent"], p, None]]; out];
  internalQ[x_] := kids[x] =!= {};
  forced = Association[Thread[Select[pinned, KeyExistsQ[pos, #] &] -> True]];
  displayedQ[x_] := x === root || KeyExistsQ[forced, x] ||
    With[{p = Lookup[tree["Parent"], x, None]}, KeyExistsQ[mode, p] && MemberQ[Lookup[shown, p, {}], x]];
  (* \:679a\:306b\:306a\:308b\:306e\:306f: \:6839\:3001\:8449\:3001\:958b\:3044\:3066\:3044\:306a\:3044 (\:307e\:305f\:306f\:4e00\:90e8\:3060\:3051\:958b\:3044\:305f) \:7bc0\:3001\:6d45\:3044 (\:9053\:6a19\:306e) \:958b\:3044\:305f\:7bc0 *)
  slideQ[x_] := displayedQ[x] && (x === root || ! internalQ[x] || Lookup[mode, x, None] =!= "Expanded" || depth[x] <= h);
  count[] := Count[order, _?slideQ];
  While[True,
    remaining = nSlides - count[];
    cands = Select[order, internalQ[#] && displayedQ[#] && ! KeyExistsQ[mode, #] &];
    If[cands === {}, Break[]];
    c = First[SortBy[cands, {depth, -prio[#] &, pos[#] &}]];
    new = Select[kids[c], ! displayedQ[#] &];
    delta = Length[new] - If[c =!= root && depth[c] > h, 1, 0];
    Which[
      delta <= remaining, mode[c] = "Expanded"; shown[c] = kids[c],
      remaining >= 1,
        mode[c] = "Partial";
        shown[c] = With[{add = Take[SortBy[new, {-prio[#] &, pos[#] &}], UpTo[remaining]]}, Select[kids[c], MemberQ[add, #] || displayedQ[#] &]];
        Break[],
      True, Break[]]];
  partial = Select[Keys[mode], mode[#] === "Partial" &];
  slides = Select[order, slideQ];
  internal = Select[order, internalQ];
  figOf[x_] := Module[{cand},
    cand = Select[Select[order, MemberQ[anc[#], x] &],
      AnyTrue[Replace[Lookup[index[#], "Assets", {}], Except[_List] -> {}],
        AssociationQ[#] && MemberQ[{"NotebookFigure", "PDFFigure", "PDFImage", "DeckSlide", "Image", "WLFigure"}, Lookup[#, "Type", ""]] &] &];
    If[cand === {}, None, First[MaximalBy[cand, imp]]]];
  folded = Select[order, figNode[#] && ! displayedQ[#] && ! KeyExistsQ[drop, #] &];
  weights = Map[1. + If[Replace[Lookup[index[#], "Assets", {}], Except[_List] -> {}] =!= {}, 0.4, 0.] &, slides];
  total = If[NumericQ[seconds] && seconds > 0, N[seconds], sps * Length[slides]];
  secs = If[Total[weights] > 0, Round[total * weights / Total[weights]], ConstantArray[Round[sps], Length[slides]]];
  If[secs =!= {}, secs[[-1]] += Round[total] - Total[secs]];
  If[withheld =!= {}, AppendTo[diag, "Withheld (privacy): " <> StringRiffle[withheld, ", "]]];
  If[partial =!= {}, AppendTo[diag, "Partial: " <> StringRiffle[partial, ", "]]];
  <|"ObjectClass" -> "SourceVaultKGPlan", "GraphId" -> Lookup[kg, "GraphId", ""], "Mode" -> "Toc",
    "Slides" -> MapThread[Function[{x, sec}, With[{sumQ = internalQ[x] && Lookup[mode, x, None] =!= "Expanded"},
      <|"NodeId" -> x, "Packed" -> {}, "Seconds" -> sec, "Depth" -> depth[x],
        "Flags" -> Join[Lookup[Lookup[scores, x, <||>], "Flags", {}], If[MemberQ[pinned, x], {"Pinned"}, {}],
          If[sumQ, {"Summary"}, {}], If[MemberQ[partial, x], {"Partial"}, {}]],
        "Children" -> Select[kids[x], displayedQ], "AllChildren" -> kids[x], "Expanded" -> Lookup[mode, x, None] === "Expanded",
        "Figure" -> If[sumQ && x =!= root, figOf[x], None]|>]], {slides, secs}],
    "Pruned" -> Select[order, ! displayedQ[#] &], "Assumed" -> assumed, "Withheld" -> withheld, "Hidden" -> hidden,
    "Omitted" -> omitted, "Pinned" -> pinned, "Promoted" -> {}, "Expanded" -> Select[Keys[mode], mode[#] === "Expanded" &],
    "Headings" -> Select[order, displayedQ[#] && internalQ[#] && ! slideQ[#] &], "FoldedFigures" -> folded, "Threshold" -> None,
    "Scores" -> scores, "SlideCount" -> Length[slides], "TotalSeconds" -> Total[secs],
    "Audience" -> SourceVaultKGAudience[OptionValue["Audience"]], "Diagnostics" -> diag,
    "TreeParent" -> tree["Parent"], "TreeInternal" -> internal|>];

(* \:5b50\:306e\:4e00\:884c: \:4e00\:884c\:8981\:7d04 (Gist) \:304c\:3042\:308c\:3070\:305d\:308c\:3001\:7121\:3051\:308c\:3070\:984c\:76ee *)
iKGOneLiner[n_Association, lang_, primary_] := If[iKGHasGistQ[n, lang, primary], SourceVaultKGText[n, "Gist", lang], SourceVaultKGText[n, "Label", lang]];
iKGOneLiner[___] := "";
iKGAgendaTalk[lines_List, lang_] := If[lang === "ja",
  "\:672c\:65e5\:306f " <> ToString[Length[lines]] <> " \:90e8\:306b\:5206\:3051\:3066\:304a\:8a71\:3057\:3057\:307e\:3059\:3002" <>
    StringJoin[MapIndexed["\:7b2c" <> ToString[First[#2]] <> "\:90e8\:3067\:306f\:3001" <> StringTrim[#1, "\:3002"] <> "\:3092\:6271\:3044\:307e\:3059\:3002" &, lines]],
  "The talk has " <> ToString[Length[lines]] <> " parts. " <>
    StringJoin[MapIndexed["Part " <> ToString[First[#2]] <> " covers " <> StringTrim[#1, "."] <> ". " &, lines]]];

(* ---------------- v1.47: \:4ed6\:306e KG \:306e\:30ce\:30fc\:30c9\:3092\:53d6\:308a\:8fbc\:3080 (\:8a08\:7b97\:30ce\:30fc\:30c8\:306e\:5358\:4f4d\:306e\:518d\:5229\:7528\:306a\:3069) ----------------
   from \:306e ids (\:3068\:305d\:306e Contains \:306e\:5b50\:5b6b) \:3092\:65b0\:3057\:3044 Id (Prefix + \:5143\:306e Id) \:3067 kg \:306b\:5199\:3059\:3002\:4e2d\:306e\:8fba\:3082\:5199\:3057\:3001\:3044\:3061\:3070\:3093\:4e0a\:306e\:30ce\:30fc\:30c9\:306f "Parent" \:306e
   Contains \:306e\:5b50\:306b ("After" \:304c\:3042\:308c\:3070\:305d\:306e\:5f8c\:308d)\:3002\:5143\:306f "Origin" -> <|Graph, Id|> \:306b\:6b8b\:3059\:3002\:56f3\:306a\:3069\:306e\:8cc7\:7523\:306e\:53c2\:7167 (Ref) \:306f\:305d\:306e\:307e\:307e
   (\:8a08\:7b97\:30ce\:30fc\:30c8\:306e Ref \:306f sv://computenb/<Id> \:306a\:306e\:3067\:3069\:306e KG \:304b\:3089\:3082\:89e3\:3051\:308b)\:3002\:30ce\:30fc\:30c9\:306e "Links" ("<GraphId>#<Id>") \:304c kg \:306e
   \:30ce\:30fc\:30c9\:3092\:6307\:3057\:3066\:3044\:308c\:3070 Supports \:306e\:8fba\:306b\:3059\:308b\:3002\:76ee\:6b21\:304c\:3042\:308b kg \:3067\:306f\:3001\:65b0\:3057\:3044\:30ce\:30fc\:30c9\:306f\:76ee\:6b21\:306e\:6728\:304c After / Parent \:306e\:6240\:306b\:7f6e\:304f *)
Options[SourceVaultKGImportNodes] = {"Prefix" -> Automatic, "Parent" -> Automatic, "After" -> None, "Subtree" -> True,
  "Pin" -> False, "Link" -> True};
SourceVaultKGImportNodes[kg_Association, from_Association, ids_, OptionsPattern[]] := Module[
  {fi = iKGNodeIndex[from], ti = iKGNodeIndex[kg], froot = Lookup[from, "Root", None], troot = Lookup[kg, "Root", "root"],
   fgid = ToString[Lookup[from, "GraphId", ""]], tgid = ToString[Lookup[kg, "GraphId", ""]], sel, kids, base, prefix, k = 0,
   map, cpar, tops, parent, after, o0, newNodes, newEdges = {}, linked = 0, srcs},
  sel = Select[If[ids === All, Keys[fi], iKGList[ids]], StringQ[#] && KeyExistsQ[fi, #] && # =!= froot &];
  kids = GroupBy[Select[Lookup[from, "Edges", {}], #["EdgeKind"] === "Contains" &], (#["From"] &) -> (#["To"] &)];
  If[TrueQ[OptionValue["Subtree"]],
    sel = FixedPoint[DeleteDuplicates[Join[#, Flatten[Lookup[kids, #, {}]]]] &, sel, 50];
    sel = Select[sel, # =!= froot &]];
  sel = SortBy[sel, {Replace[Lookup[fi[#], "Order", None], Except[_?NumericQ] -> 10.^6] &, # &}];
  If[sel === {}, Return[<|"KG" -> kg, "Added" -> {}, "Map" -> <||>, "Linked" -> 0|>]];
  base = Replace[OptionValue["Prefix"], Automatic :> StringTake[StringReplace[ToLowerCase[fgid], Except[LetterCharacter | DigitCharacter] -> ""], UpTo[12]] <> "_"];
  If[! StringQ[base] || base === "_", base = "imp_"];
  prefix = base;
  While[AnyTrue[sel, KeyExistsQ[ti, prefix <> #] &] && k < 100, k++; prefix = StringDrop[base, -1] <> ToString[k] <> "_"];
  map = AssociationThread[sel -> Map[prefix <> # &, sel]];
  cpar = Association[Map[#["To"] -> #["From"] &, Reverse[Select[Lookup[from, "Edges", {}], #["EdgeKind"] === "Contains" &]]]];
  tops = Select[sel, ! KeyExistsQ[map, Lookup[cpar, #, None]] &];
  parent = Replace[OptionValue["Parent"], Automatic -> troot];
  If[! KeyExistsQ[ti, parent], parent = troot];
  after = OptionValue["After"];
  If[! (StringQ[after] && KeyExistsQ[ti, after]), after = None];
  o0 = Which[
    after =!= None && NumericQ[Lookup[ti[after], "Order", None]], ti[after]["Order"],
    True, Max[Prepend[Select[Lookup[Lookup[kg, "Nodes", {}], "Order", None], NumericQ], 0]] + 1];
  newNodes = MapIndexed[Function[{id, i}, Join[fi[id],
      <|"Id" -> map[id], "Order" -> o0 + 0.001 First[i], "Origin" -> <|"Graph" -> fgid, "Id" -> id|>|>,
      If[TrueQ[OptionValue["Pin"]] && MemberQ[tops, id], <|"Pinned" -> True|>, <||>]]], sel];
  newEdges = Map[Join[#, <|"From" -> map[#["From"]], "To" -> map[#["To"]]|>] &,
    Select[Lookup[from, "Edges", {}], KeyExistsQ[map, #["From"]] && KeyExistsQ[map, #["To"]] &]];
  newEdges = Join[newEdges, Map[<|"From" -> parent, "To" -> map[#], "EdgeKind" -> "Contains", "Weight" -> 1.|> &, tops]];
  If[after =!= None, AppendTo[newEdges, <|"From" -> after, "To" -> map[First[tops]], "EdgeKind" -> "Precedes", "Weight" -> 0.9|>]];
  If[TrueQ[OptionValue["Link"]],
    Do[Do[With[{p = StringSplit[l, "#", 2]},
          If[Length[p] === 2 && (p[[1]] === tgid || p[[1]] === "") && KeyExistsQ[ti, p[[2]]],
            linked++; AppendTo[newEdges, <|"From" -> map[id], "To" -> p[[2]], "EdgeKind" -> "Supports", "Weight" -> 0.6|>]]],
        {l, Select[iKGList[Lookup[fi[id], "Links", {}]], StringQ]}],
      {id, sel}]];
  srcs = Lookup[kg, "Sources", {}];
  Do[If[AssociationQ[s] && ! MemberQ[Lookup[Select[srcs, AssociationQ], "Key", {}], Lookup[s, "Key", None]], AppendTo[srcs, s]],
    {s, Select[iKGList[Lookup[from, "Sources", {}]], AssociationQ]}];
  <|"KG" -> SourceVaultKGValidate[Join[kg, <|"Nodes" -> Join[Lookup[kg, "Nodes", {}], newNodes],
      "Edges" -> Join[Lookup[kg, "Edges", {}], newEdges], "Sources" -> srcs|>]],
    "Added" -> Lookup[map, sel], "Map" -> map, "Linked" -> linked|>];

iKGSubtree[tree_Association, id_String] := Module[{out = {id}, q = {id}, c},
  While[q =!= {},
    c = Flatten[Lookup[tree["Children"], q, {}]];
    out = Join[out, c]; q = c];
  out];

Options[SourceVaultKGLevelSummaries] = {"Language" -> Automatic};
SourceVaultKGLevelSummaries[kg_Association, tree_Association, OptionsPattern[]] := Module[
  {lang = Replace[OptionValue["Language"], Automatic -> Lookup[kg, "Language", "ja"]], index = iKGNodeIndex[kg]},
  Association[Map[Function[id,
    With[{n = index[id], kids = Lookup[tree["Children"], id, {}]},
      id -> <|"Depth" -> tree["Depth"][id], "Label" -> SourceVaultKGText[n, "Label", lang],
        "Summary" -> With[{s = SourceVaultKGText[n, "Summary", lang]},
          If[s === "", SourceVaultKGText[n, "Label", lang], s]],
        "Children" -> (SourceVaultKGText[index[#], "Label", lang] & /@ kids),
        "Subtree" -> Length[iKGSubtree[tree, id]] - 1|>]],
    Select[tree["Order"], Lookup[tree["Children"], #, {}] =!= {} &]]]];

iKGOrderViolations[kg_Association, pos_Association] := Select[Map[Function[e,
    If[TrueQ[e["Order"]] && KeyExistsQ[pos, e["From"]] && KeyExistsQ[pos, e["To"]] && pos[e["From"]] > pos[e["To"]],
      <|"From" -> e["From"], "To" -> e["To"], "EdgeKind" -> e["EdgeKind"]|>, Nothing]],
  Lookup[kg, "Edges", {}]], AssociationQ];

SourceVaultKGVerify[kg_Association, tree_Association] := Module[{pos, viol, orphans, dropped, status},
  pos = AssociationThread[tree["Order"] -> Range[Length[tree["Order"]]]];
  orphans = Complement[Lookup[Lookup[kg, "Nodes", {}], "Id", {}], tree["Order"]];
  (* \:76ee\:6b21\:306e\:6728\:306b\:5165\:3089\:306a\:3044\:30ce\:30fc\:30c9 (\:4f7f\:308f\:306a\:3044\:3068\:6c7a\:3081\:305f\:8449\:30fb\:8cc7\:6599\:306e\:7bc0) \:306f\:843d\:3061\:305f\:306e\:3067\:306f\:306a\:3044 *)
  If[Lookup[tree, "Strategy", ""] === "Toc", orphans = {}];
  dropped = Lookup[tree["Diagnostics"], "Dropped", {}];
  (* \:9589\:8def\:3092\:5207\:308b\:305f\:3081\:306b\:843d\:3068\:3057\:305f\:8fba\:306f\:9055\:53cd\:3067\:306f\:306a\:3044 (Cycles \:306b\:51fa\:308b) *)
  viol = Select[iKGOrderViolations[kg, pos],
    Function[v, ! AnyTrue[dropped, #["From"] === v["From"] && #["To"] === v["To"] &]]];
  status = Which[viol =!= {} || orphans =!= {}, "Broken",
    dropped =!= {} || Lookup[tree["Diagnostics"], "RootMismatch", None] =!= None, "Warnings", True, "OK"];
  <|"Status" -> status, "OrderViolations" -> viol, "Cycles" -> Select[dropped, #["Reason"] === "Cycle" &],
    "RootIncomingDropped" -> Select[dropped, #["Reason"] === "RootIncoming" &],
    "Orphans" -> orphans, "RootMismatch" -> Lookup[tree["Diagnostics"], "RootMismatch", None],
    "MissingPrerequisites" -> {}|>];

(* ---------------- \:8a70\:3081\:8fbc\:307f\:3068\:679d\:5208\:308a ---------------- *)

(* s \:306e\:5b50\:5b6b\:306e\:3046\:3061\:3001\:30b9\:30e9\:30a4\:30c9\:3068\:3057\:3066\:63d0\:793a\:3055\:308c\:308b\:6700\:3082\:8fd1\:3044\:3082\:306e (\:5b50\:304c\:30b9\:30e9\:30a4\:30c9\:306a\:3089\:305d\:306e\:5b50\:3001\:3067\:306a\:3051\:308c\:3070\:305d\:306e\:5b50\:306e\:4e0b\:3092\:63a2\:3059) *)
iKGSlideChildren[tree_Association, slides_List, s_String] := Flatten[Map[Function[c,
  If[MemberQ[slides, c], {c}, iKGSlideChildren[tree, slides, c]]], Lookup[tree["Children"], s, {}]]];

Options[SourceVaultKGPlan] = {"Slides" -> Automatic, "Seconds" -> Automatic, "SecondsPerSlide" -> 25.,
  "Audience" -> Automatic, "MaxPackedPerSlide" -> 4, "PackRatio" -> 0.35, "ReleaseCeiling" -> 0.5,
  "MinSlides" -> 3, "ForceParts" -> 0.5};
SourceVaultKGPlan[kg_Association, tree_Association, OptionsPattern[]] := Module[
  {index = iKGNodeIndex[kg], scores, order = tree["Order"], root = tree["Root"], nSlides, seconds, floor = OptionValue["ForceParts"],
   sps = N[OptionValue["SecondsPerSlide"]], assumed, withheld, cands, forced, parts, take, theta, slides,
   packed = <||>, host = <||>, pruned, promoted = {}, cap = OptionValue["MaxPackedPerSlide"],
   ratio = OptionValue["PackRatio"], ceiling = OptionValue["ReleaseCeiling"], remaining, pos, diag = {},
   weights, total, secs, presented, packSet, posOf, oedges, predsOf, succOf, slideAncestor, subtreeSlides,
   presentedPos, hostFor, hidden, pinned},
  scores = SourceVaultKGScores[kg, OptionValue["Audience"]];
  (* privacy: fail-closed *)
  withheld = Select[order, index[#]["PrivacyLevel"] > ceiling &];
  (* \:8abf\:6574\:3067\:300c\:96a0\:3059\:300d\:306b\:3057\:305f\:30ce\:30fc\:30c9 (Hidden) \:306f\:30b9\:30e9\:30a4\:30c9\:306b\:3082\:8a70\:3081\:8fbc\:307f\:306b\:3082\:524d\:63d0\:306e\:4fee\:5fa9\:306b\:3082\:4f7f\:308f\:306a\:3044 *)
  hidden = Select[order, TrueQ[Lookup[index[#], "Hidden", False]] && # =!= root &];
  order = Complement[order, withheld, hidden] // SortBy[FirstPosition[tree["Order"], #] &];
  assumed = Select[order, MemberQ[scores[#]["Flags"], "Assumed"] && # =!= root &];
  (* v1.42: \:300c\:5fc5\:305a\:51fa\:3059\:300d\:30ce\:30fc\:30c9 (Pinned\:3002\:8abf\:6574\:3067\:8db3\:3057\:305f\:679a\:3084\:300c\:5fc5\:305a\:542b\:3081\:308b\:300d\:3068\:8a00\:308f\:308c\:305f\:679a) \:306f\:524d\:63d0\:77e5\:8b58\:6271\:3044\:306b\:3082
     \:70b9\:6570\:306e\:7af6\:4e89\:306b\:3082\:305b\:305a\:3001\:90e8\:3068\:540c\:3058\:304f\:5148\:306b\:67a0\:3092\:53d6\:308b\:3002\:67a0\:3088\:308a\:591a\:3051\:308c\:3070\:67a0\:3092\:8d85\:3048\:3066\:3082\:51fa\:3059\:3002\:96a0\:3059\:30fb\:975e\:516c\:958b\:306f\:9664\:3044\:305f\:5f8c *)
  pinned = Select[order, TrueQ[Lookup[index[#], "Pinned", False]] && # =!= root &];
  assumed = Select[assumed, ! MemberQ[pinned, #] &];
  seconds = OptionValue["Seconds"];
  nSlides = OptionValue["Slides"];
  If[! IntegerQ[nSlides] || nSlides < 1,
    nSlides = Which[NumericQ[seconds] && seconds > 0, Max[1, Round[seconds / sps]],
      True, Length[order] - Length[assumed]]];
  nSlides = Max[nSlides, Min[OptionValue["MinSlides"], Length[order]]];
  cands = Select[order, # =!= root && ! MemberQ[assumed, #] &];
  (* \:90e8 (root \:76f4\:4e0b) \:306f\:5fc5\:305a 1 \:679a\:306b\:3059\:308b\:3002\:305f\:3060\:3057 Importance \:304c "ForceParts" (\:65e2\:5b9a 0.5) \:672a\:6e80\:306e\:90e8 (\:4ed8\:9332\:306a\:3069) \:306f
     \:5f37\:5236\:305b\:305a\:3001\:4ed6\:306e\:30ce\:30fc\:30c9\:3068\:540c\:3058\:9806\:4f4d\:3065\:3051\:306b\:4efb\:305b\:308b (None \:3067\:5168\:90e8\:3092\:5f37\:5236) *)
  parts = Select[Lookup[tree["Children"], root, {}], MemberQ[cands, #] &&
    (! NumericQ[floor] || Lookup[index[#], "Importance", 0.5] >= floor) &];
  forced = DeleteDuplicates[Join[If[nSlides >= 1 + Length[Union[parts, pinned]], parts, {}], pinned]];
  remaining = Select[cands, ! MemberQ[forced, #] &];
  take = Max[0, nSlides - 1 - Length[forced]];
  remaining = SortBy[remaining, {-scores[#]["Score"], FirstPosition[order, #]} &];
  slides = Join[{root}, forced, Take[remaining, UpTo[take]]];
  theta = If[take > 0 && Length[remaining] > 0, scores[remaining[[Min[take, Length[remaining]]]]]["Score"], 1.];
  slides = SortBy[slides, FirstPosition[order, #] &];
  (* \:8a70\:3081\:8fbc\:307f\:5148\:306e\:898f\:5247 (\:9806\:5e8f\:3092\:58ca\:3055\:306a\:3044):
       x \:306e\:6700\:5bc4\:308a\:306e\:30b9\:30e9\:30a4\:30c9\:5148\:7956 A \:306e\:90e8\:5206\:6728\:306b\:3042\:308b\:30b9\:30e9\:30a4\:30c9\:306e\:3046\:3061\:3001\:4f4d\:7f6e\:304c x \:4ee5\:524d\:3067\:3001\:304b\:3064
       x \:306e\:63d0\:793a\:6e08\:307f\:5148\:884c\:30ce\:30fc\:30c9\:306e\:4f4d\:7f6e\:4ee5\:4e0a\:30fb\:5f8c\:7d9a\:30ce\:30fc\:30c9\:306e\:4f4d\:7f6e\:4ee5\:4e0b\:306e\:3082\:306e\:306e\:4e2d\:304b\:3089\:6700\:3082\:5f8c\:308d\:306e\:3082\:306e\:3092\:9078\:3076\:3002
     \:5148\:7956\:30b9\:30e9\:30a4\:30c9\:3078\:8a70\:3081\:308b\:3068\:3001\:5148\:7956\:3068 x \:306e\:9593\:306b\:3042\:308b\:5148\:884c\:30ce\:30fc\:30c9\:3088\:308a\:524d\:306b\:51fa\:3066\:3057\:307e\:3046 (\:5b9f\:6e2c: \:56f3\:304c\:6a5f\:69cb\:306e\:8aac\:660e\:3088\:308a
     \:524d\:306b\:51fa\:308b / \:7d50\:8ad6\:304c\:7d50\:679c\:3088\:308a\:524d\:306b\:51fa\:308b)\:3002\:90e8\:5206\:6728\:306f L \:306e\:9023\:7d9a\:533a\:9593\:306a\:306e\:3067\:3001\:3053\:306e\:898f\:5247\:306a\:3089\:7bc0\:3092\:307e\:305f\:304c\:305a\:3001
     \:3069\:306e\:9806\:3067\:8a70\:3081\:3066\:3082\:63d0\:793a\:9806\:304c\:9806\:5e8f\:8fba\:3068\:77db\:76fe\:3057\:306a\:3044 *)
  posOf = AssociationThread[order -> Range[Length[order]]];
  oedges = Select[Lookup[kg, "Edges", {}], TrueQ[#["Order"]] &];
  predsOf = <||>; succOf = <||>;
  Do[predsOf[e["To"]] = Append[Lookup[predsOf, e["To"], {}], e["From"]];
     succOf[e["From"]] = Append[Lookup[succOf, e["From"], {}], e["To"]], {e, oedges}];
  slideAncestor[x_] := Module[{p = Lookup[tree["Parent"], x, None]},
    While[p =!= None && ! MemberQ[slides, p], p = Lookup[tree["Parent"], p, None]];
    If[p === None, root, p]];
  subtreeSlides[a_] := subtreeSlides[a] = Select[iKGSubtree[tree, a], MemberQ[slides, #] &];
  presentedPos[y_] := Which[MemberQ[slides, y], posOf[y], KeyExistsQ[host, y], posOf[host[y]], True, None];
  hostFor[x_, allowOverflow_] := Module[{cands, lb, ub, ok},
    cands = ReverseSortBy[Select[subtreeSlides[slideAncestor[x]], posOf[#] <= posOf[x] &], posOf];
    lb = Max[Prepend[Select[presentedPos /@ Lookup[predsOf, x, {}], IntegerQ], 0]];
    ub = Min[Prepend[Select[presentedPos /@ Lookup[succOf, x, {}], IntegerQ], Infinity]];
    cands = Select[cands, lb <= posOf[#] <= ub &];
    (* \:56f3\:306e\:3042\:308b\:679a\:306f\:884c\:6570\:304c\:5c11\:306a\:3044\:306e\:3067\:8a70\:3081\:8fbc\:307f\:306f\:534a\:5206\:307e\:3067 (\:7d9a\:304d\:30b9\:30e9\:30a4\:30c9\:304c\:5897\:3048\:3059\:304e\:306a\:3044) *)
    ok = SelectFirst[cands, Length[Lookup[packed, #, {}]] < If[Lookup[index[#], "Assets", {}] =!= {}, 1, cap] &, None];
    Which[ok =!= None, ok, allowOverflow && cands =!= {}, First[cands], True, None]];
  (* \:95be\:5024\:672a\:6e80\:3067\:3082 PackRatio \:4ee5\:4e0a\:306a\:3089\:7b87\:6761\:66f8\:304d\:3068\:3057\:3066\:8a70\:3081\:8fbc\:3080 (\:5bb9\:91cf\:306e\:3042\:308b\:5148\:304c\:7121\:3051\:308c\:3070\:843d\:3068\:3059) *)
  Do[If[! MemberQ[slides, x] && ! MemberQ[assumed, x] && scores[x]["Score"] >= theta * ratio,
      With[{h = hostFor[x, False]},
        If[h =!= None, packed[h] = Append[Lookup[packed, h, {}], x]; host[x] = h]]],
    {x, order}];
  (* \:524d\:63d0\:306e\:4fee\:5fa9: \:63d0\:793a\:3055\:308c\:308b\:30ce\:30fc\:30c9\:306e Prerequisite / Derives / Motivates \:5143\:304c\:843d\:3061\:3066\:3044\:308c\:3070\:8a70\:3081\:8fbc\:3080
     (\:5bb9\:91cf\:8d85\:904e\:3092\:8a31\:3059\:3002\:7f6e\:304d\:5834\:304c\:7121\:3051\:308c\:3070 Unplaceable \:306b\:8a18\:9332) *)
  Do[
    presented = Join[slides, Keys[host]];
    (* \:540c\:3058\:524d\:63d0\:30ce\:30fc\:30c9\:304c\:8907\:6570\:306e\:4f9d\:5b58\:5148\:304b\:3089\:6607\:683c\:3055\:308c\:3066\:4f55\:5ea6\:3082\:8a70\:3081\:8fbc\:307e\:308c\:306a\:3044\:3088\:3046\:3001host \:306f\:5373\:6642\:306b\:898b\:308b
       (\:5b9f\:6e2c: bg \:30ce\:30fc\:30c9\:304c 4 \:679a\:306b\:91cd\:8907\:3057\:3066\:73fe\:308c\:305f) *)
    Do[If[MemberQ[{"Prerequisite", "Derives", "Motivates"}, e["EdgeKind"]] && MemberQ[presented, e["To"]] &&
        ! MemberQ[presented, e["From"]] && ! KeyExistsQ[host, e["From"]] && ! MemberQ[slides, e["From"]] &&
        ! MemberQ[assumed, e["From"]] && MemberQ[order, e["From"]],
        With[{h = hostFor[e["From"], True]},
          If[h =!= None,
            packed[h] = Append[Lookup[packed, h, {}], e["From"]]; host[e["From"]] = h;
            AppendTo[promoted, e["From"]],
            AppendTo[diag, "Unplaceable prerequisite: " <> e["From"] <> " -> " <> e["To"]]]]],
      {e, oedges}],
    {3}];
  packSet = Keys[host];
  pruned = Select[order, ! MemberQ[slides, #] && ! MemberQ[packSet, #] && ! MemberQ[assumed, #] &];
  (* \:79d2\:914d\:5206 *)
  weights = Map[Function[s, 1. + 0.25 * Length[Lookup[packed, s, {}]] +
    If[Lookup[index[s], "Assets", {}] =!= {}, 0.4, 0.]], slides];
  total = If[NumericQ[seconds] && seconds > 0, N[seconds], sps * Length[slides]];
  secs = If[Total[weights] > 0, Round[total * weights / Total[weights]], ConstantArray[Round[sps], Length[slides]]];
  (* \:4e38\:3081\:306e\:8aa4\:5dee\:306f\:6700\:5f8c\:306e 1 \:679a\:3067\:5438\:53ce\:3057\:3001\:5408\:8a08\:3092\:7dcf\:79d2\:6570\:306b\:4e00\:81f4\:3055\:305b\:308b *)
  If[secs =!= {}, secs[[-1]] += Round[total] - Total[secs]];
  If[withheld =!= {}, AppendTo[diag, "Withheld (privacy): " <> StringRiffle[withheld, ", "]]];
  <|"ObjectClass" -> "SourceVaultKGPlan", "GraphId" -> Lookup[kg, "GraphId", ""],
    "Slides" -> MapThread[Function[{s, sec},
      <|"NodeId" -> s, "Packed" -> SortBy[Lookup[packed, s, {}], FirstPosition[order, #] &],
        "Seconds" -> sec, "Depth" -> tree["Depth"][s],
        "Flags" -> If[MemberQ[pinned, s], Append[scores[s]["Flags"], "Pinned"], scores[s]["Flags"]],
        (* \:7bc0\:30b9\:30e9\:30a4\:30c9\:306e\:76ee\:6b21\:7528: \:90e8\:5206\:6728\:306e\:4e2d\:3067\:30b9\:30e9\:30a4\:30c9\:306b\:306a\:3063\:305f\:76f4\:8fd1\:306e\:5b50\:5b6b (\:5b50\:304c\:30b9\:30e9\:30a4\:30c9\:3067\:306a\:3051\:308c\:3070\:305d\:306e\:4e0b\:3092\:8fbf\:308b) *)
        "Children" -> Select[iKGSlideChildren[tree, slides, s], # =!= s &]|>], {slides, secs}],
    "Pruned" -> pruned, "Assumed" -> assumed, "Withheld" -> withheld, "Hidden" -> hidden, "Pinned" -> pinned,
    "Promoted" -> DeleteDuplicates[promoted],
    "Threshold" -> theta, "Scores" -> scores, "SlideCount" -> Length[slides],
    "TotalSeconds" -> Total[secs], "Audience" -> SourceVaultKGAudience[OptionValue["Audience"]],
    "Diagnostics" -> diag|>];

SourceVaultKGVerifyPlan[kg_Association, plan_Association] := Module[{pos = <||>, viol},
  MapIndexed[Function[{s, i},
    pos[s["NodeId"]] = First[i];
    Do[pos[p] = First[i], {p, s["Packed"]}]], plan["Slides"]];
  viol = Select[Map[Function[e,
    If[TrueQ[e["Order"]] && KeyExistsQ[pos, e["From"]] && KeyExistsQ[pos, e["To"]] && pos[e["From"]] > pos[e["To"]],
      <|"From" -> e["From"], "To" -> e["To"], "EdgeKind" -> e["EdgeKind"], "Slides" -> {pos[e["From"]], pos[e["To"]]}|>, Nothing]],
    Lookup[kg, "Edges", {}]], AssociationQ];
  <|"Status" -> If[viol === {}, "OK", "Broken"], "Violations" -> viol|>];

(* ---------------- \:30a2\:30a6\:30c8\:30e9\:30a4\:30f3 (\:8a00\:8a9e\:5225) ---------------- *)

Options[SourceVaultKGOutline] = {"Language" -> Automatic, "MaxAssetsPerSlide" -> 2, "MaxPointsPerSlide" -> 6,
  "MaxLinesPerSlide" -> 9, "CharsPerLine" -> 40, "FigureLines" -> 4, "Agenda" -> Automatic, "Roadmap" -> True,
  "Crumbs" -> True, "CharsPerSecond" -> Automatic, "ReShowFigures" -> True,
  "InheritFigures" -> True, "FigureReuse" -> 2, "Glossary" -> Automatic, "GlossaryRows" -> 6};

(* 1 \:884c\:306e\:8868\:793a\:30b3\:30b9\:30c8: \:9577\:3044\:884c\:306f\:6298\:308a\:8fd4\:3057\:3066 2 \:884c\:4ee5\:4e0a\:3092\:5360\:3081\:308b (16:9 \:3067 1 \:884c \[TildeTilde] 40 \:5168\:89d2\:5b57) *)
iKGLineCost[s_String, cpl_Integer] := Max[1, Ceiling[StringLength[s] / Max[10, cpl]]];
iKGLineCost[_, _] := 1;
(* 1 \:679a\:306e\:884c\:6570: \:5c0e\:5165\:6587 + \:8981\:70b9 (+ \:88dc\:8db3) + \:8a70\:3081\:8fbc\:3093\:3060\:5b50 (\:30e9\:30d9\:30eb + \:884c) *)
iKGSlideLines[lead_String, points_List, details_List, sub_List, cpl_Integer] :=
  If[lead === "", 0, iKGLineCost[lead, cpl]] +
  Total[iKGLineCost[#, cpl] & /@ points] +
  Total[iKGLineCost[#, cpl] & /@ Select[details, StringQ[#] && # =!= "" &]] +
  Total[Map[iKGLineCost[#["Label"], cpl] + Total[iKGLineCost[#, cpl] & /@ #["Points"]] &, sub]];
iKGSlideLines[points_List, sub_List, cpl_Integer] := iKGSlideLines["", points, {}, sub, cpl];

(* 1 \:679a\:306e\:884c\:6570\:3092\:4e88\:7b97\:306b\:53ce\:3081\:308b\:30021. \:672b\:5c3e\:306e\:5b50\:306e\:884c \[RightArrow] 2. \:88dc\:8db3\:3092\:672b\:5c3e\:304b\:3089 \[RightArrow] 3. \:81ea\:8eab\:306e\:8981\:70b9\:3092 minOwn \:884c\:307e\:3067 \[RightArrow]
   4. \:305d\:308c\:3067\:3082\:8d85\:3048\:308b\:5b50\:306f\:300c\:7d9a\:304d\:300d\:30b9\:30e9\:30a4\:30c9\:3078 (\:884c\:306f\:5143\:306b\:623b\:3057\:3066\:6e21\:3059)\:3002
   \:65e7\:5b9f\:88c5\:306f Total[.., 0] \:306e\:8aa4\:308a\:3067\:4e00\:5ea6\:3082\:524a\:308c\:306a\:304b\:3063\:305f (\:5b9f\:6e2c: 1 \:679a 29 \:884c)\:3002 *)
iKGFitLines[lead_String, points_List, detailsIn_List, subIn_List, budget_Integer, cpl_Integer, minOwn_: 2] :=
  Module[{pts = points, det = PadRight[Take[detailsIn, UpTo[Length[points]]], Length[points], ""], sub = subIn, k, overflow = {}, orig, lines},
  orig = Association[Map[#["NodeId"] -> # &, subIn]];
  lines[] := iKGSlideLines[lead, pts, det, sub, cpl];
  k = Length[sub];
  While[lines[] > budget && k >= 1,
    If[sub[[k, "Points"]] =!= {}, sub[[k, "Points"]] = Most[sub[[k, "Points"]]], k--]];
  k = Length[det];
  While[lines[] > budget && k >= 1, If[det[[k]] =!= "", det[[k]] = "", k--]];
  While[lines[] > budget && Length[pts] > minOwn, pts = Most[pts]; det = Most[det]];
  While[lines[] > budget && Length[sub] > 0,
    PrependTo[overflow, orig[Last[sub]["NodeId"]]]; sub = Most[sub]];
  {pts, det, sub, overflow}];
iKGFitLines[points_List, subIn_List, budget_Integer, cpl_Integer, minOwn_: 2] :=
  With[{r = iKGFitLines["", points, {}, subIn, budget, cpl, minOwn]}, {r[[1]], r[[3]], r[[4]]}];

iKGSentences[t_String, lang_String] := Select[StringTrim /@ StringSplit[t, If[lang === "ja", "\:3002", ". "]], # =!= "" &];
(* \:30ce\:30fc\:30c9\:306e\:539f\:7a3f: Talk (\:8981\:70b9\:9806\:306e\:6587) \:3092\:8868\:793a\:3057\:305f\:8981\:70b9\:6570 + 1 \:6587\:306b\:5207\:308a\:8a70\:3081\:308b\:3002\:7121\:3051\:308c\:3070\:8981\:70b9\:3092\:305d\:306e\:307e\:307e\:6587\:306b (Summary \:306f\:8981\:70b9\:3068
   \:5bfe\:5fdc\:3057\:306a\:3044\:3053\:3068\:304c\:3042\:308b)\:3002\:8981\:70b9\:3082\:7121\:3051\:308c\:3070 Summary *)
iKGNodeTalk[n_Association, nShown_Integer, lang_String] := Module[{t = SourceVaultKGText[n, "Talk", lang], ss},
  If[t === "", Return[With[{ps = SourceVaultKGText[n, "Points", lang]},
    If[ListQ[ps] && Select[ps, StringQ] =!= {}, iKGTalkFallback[Take[Select[ps, StringQ], UpTo[Max[1, nShown]]], "", lang],
      SourceVaultKGText[n, "Summary", lang]]]]];
  ss = iKGSentences[t, lang];
  If[nShown >= 1 && Length[ss] > nShown + 1, ss = Take[ss, nShown + 1]];
  If[ss === {}, "", StringRiffle[ss, If[lang === "ja", "\:3002", ". "]] <> If[lang === "ja", "\:3002", "."]]];
(* \:539f\:7a3f\:306e\:9577\:3055\:4e0a\:9650: \:79d2\:6570 \[Times] \:8a71\:901f (ja 7 \:5b57/\:79d2\:3001en 14 \:5b57/\:79d2) \:3068\:3001\:8868\:793a\:884c\:6570 + 2 \:6587\:3002\:6587\:306e\:5207\:308c\:76ee\:3067\:5207\:308b *)
iKGCapTalk[talk_String, seconds_, lang_String, maxSentences_Integer, cpsIn_] := Module[
  {ss = iKGSentences[talk, lang], cps, maxChars, out = {}, len = 0, sep = If[lang === "ja", "\:3002", ". "]},
  cps = If[NumericQ[cpsIn] && cpsIn > 0, cpsIn, If[lang === "ja", 7., 14.]];
  maxChars = Max[80, Round[If[NumericQ[seconds] && seconds > 0, seconds, 25] * cps]];
  Do[If[out === {} || (len + StringLength[s] <= maxChars && Length[out] < Max[1, maxSentences]),
      AppendTo[out, s]; len += StringLength[s]], {s, ss}];
  If[out === {}, "", StringRiffle[out, sep] <> StringTrim[sep]]];
iKGFirstSentence[t_String, lang_String] := With[{ss = iKGSentences[t, lang]},
  If[ss === {}, "", First[ss] <> If[lang === "ja", "\:3002", "."]]];

(* \:672c\:6587\:4e2d\:306e\:56f3\:8868\:756a\:53f7\:306e\:8a00\:53ca: \:56f32 / \:56f3 2 / Figure 2 / Fig. 2 *)
iKGFigureRefs[t_String] := DeleteDuplicates[StringCases[t,
  ("\:56f3" | "Figure" | "Fig." | "Fig") ~~ WhitespaceCharacter ... ~~ d : DigitCharacter .. :> ToExpression[d]]];
(* \:56f3\:8868\:756a\:53f7\:306e\:8a00\:53ca 1 \:3064\:5206 (\:56f32 / \:56f3 7A / Figure 3 / \:88681 / Table 2-1) *)
$iKGRefToken = RegularExpression["(?:\:56f3|\:8868|Figure|Fig\\.|Fig|Table|Tab\\.)[ \:3000]*[0-9]+(?:[A-Za-z]\\b|[-\[Dash]][0-9]+)?"];
(* keep \:306b\:7121\:3044\:56f3\:3068\:3001\:30b9\:30e9\:30a4\:30c9\:306b\:8f09\:3089\:306a\:3044\:8868\:306e\:8a00\:53ca\:3092\:843d\:3068\:3059 *)
iKGStripRefTokens[t_String, keep_List] := StringReplace[t, tok : $iKGRefToken :>
  If[StringStartsQ[tok, "\:8868" | "Table" | "Tab."] || ! AnyTrue[iKGFigureRefs[tok], MemberQ[keep, #] &], "", tok]];
(* \:30b9\:30e9\:30a4\:30c9\:306b\:7121\:3044\:56f3\:8868\:3078\:306e\:8a00\:53ca\:3092\:6d88\:3059\:3002\:62ec\:5f27\:306e\:4e2d\:306f\:533a\:5207\:308a\:3054\:3068\:306b\:898b\:3066\:3001\:56f3\:8868\:756a\:53f7\:3060\:3051\:306e\:9805\:76ee\:3092\:843d\:3068\:3059:
   (\:56f32) / \:ff08\:56f32, \:88681\:ff09 \:306f\:4e38\:3054\:3068\:3001"(\:56f37A, 1,450 s)" \:306f "(1,450 s)" \:306b\:306a\:308b\:3002
   \:9805\:76ee\:304c\:5730\:306e\:6587\:306e\:3068\:304d\:306f\:6587\:304c\:58ca\:308c\:308b\:306e\:3067\:6b8b\:3059 ("(\:56f32 \:306e A \:533a\:9593)")\:3002
   \:62ec\:5f27\:306e\:5916\:306f\:3001\:884c\:982d\:306e "Figure 9A: \[Ellipsis]" \:306e\:3088\:3046\:306a\:524d\:7f6e\:304d\:3060\:3051\:843d\:3068\:3059 *)
iKGStripFigureRefs[t_String, keep_List] := Module[{s, trim, dropQ},
  trim[x_String] := StringTrim[x, (WhitespaceCharacter | "," | "\:3001" | "\:30fb" | ";" | "\:ff1b" | "/" | "-" | "\[Dash]") ..];
  dropQ[item_String] := With[{r = iKGStripRefTokens[item, keep]}, r =!= item && trim[r] === ""];
  s = StringReplace[t, whole : (("(" | "\:ff08") ~~ inner : Shortest[Except[")" | "\:ff09"] ..] ~~ (")" | "\:ff09")) :>
    Module[{parts = StringSplit[inner, x : ("," | "\:3001" | ";" | "\:ff1b") :> x], items, seps, keepIdx, res},
      items = parts[[1 ;; ;; 2]]; seps = If[Length[parts] >= 2, parts[[2 ;; ;; 2]], {}];
      keepIdx = Select[Range[Length[items]], ! dropQ[items[[#]]] &];
      Which[
        Length[keepIdx] === Length[items], whole,
        keepIdx === {}, "",
        True,
          res = trim[StringJoin[MapIndexed[If[First[#2] === 1, items[[#1]], seps[[#1 - 1]] <> items[[#1]]] &, keepIdx]]];
          If[res === "", "", StringTake[whole, 1] <> res <> StringTake[whole, -1]]]]];
  s = StringReplace[s, StartOfString ~~ tok : $iKGRefToken ~~ sep : (WhitespaceCharacter ... ~~ (":" | "\:ff1a") ~~ WhitespaceCharacter ...) :>
    If[iKGStripRefTokens[tok, keep] === tok, tok <> sep, ""]];
  StringTrim[StringReplace[s, {"  " -> " ", " \:3002" -> "\:3002", " \:3001" -> "\:3001", " ." -> ".", " ," -> ","}]]];
iKGStripFigureRefs[x_, _] := x;
(* KG \:306e\:56f3\:30ce\:30fc\:30c9 \[RightArrow] \:8ad6\:6587\:4e2d\:306e\:756a\:53f7 (\:30ad\:30e3\:30d7\:30b7\:30e7\:30f3\:306e\:756a\:53f7 > \:51fa\:73fe\:9806) \:3068\:8cc7\:7523 *)
iKGFigureNumberOf[n_Association] := With[{src = Lookup[n, "Source", <||>]},
  With[{c = Lookup[If[AssociationQ[src], src, <||>], "Caption", None]},
    If[IntegerQ[c], c, With[{f = Lookup[If[AssociationQ[src], src, <||>], "Figure", None]}, If[IntegerQ[f], f, None]]]]];
(* \:8cc7\:7523\:306e\:540c\:4e00\:6027: \:7a2e\:985e\:30fb\:53c2\:7167\:30fb\:756a\:53f7\:30fb\:30da\:30fc\:30b8\:30fb\:5207\:308a\:51fa\:3057 (PDF \:306e\:57cb\:3081\:8fbc\:307f\:753b\:50cf\:306f\:30da\:30fc\:30b8\:3068\:756a\:53f7\:306e\:7d44\:3067\:6c7a\:307e\:308b) *)
iKGAssetKey[a_Association] := {Lookup[a, "Type", ""], Lookup[a, "Ref", ""], Lookup[a, "N", None], Lookup[a, "Page", None], Lookup[a, "Crop", None]};
(* \:30b9\:30e9\:30a4\:30c9\:306e\:56f3\:306e\:89e3\:6c7a: \:8a00\:53ca\:3055\:308c\:305f\:56f3\:304c\:3053\:306e\:679a\:306b\:7121\:3051\:308c\:3070\:518d\:63b2 (\:67a0\:304c\:3042\:308c\:3070)\:3002
   \:623b\:308a\:306f {\:3053\:306e\:679a\:306e\:8cc7\:7523, \:3053\:306e\:679a\:306b\:3042\:308b\:56f3\:306e\:756a\:53f7} *)
iKGResolveFigs[texts_List, assetsIn_List, figNodes_List, figNumOf_Association, figByNum_Association, maxA_, reshowQ_] :=
  Module[{assets = assetsIn, refs, on},
    on[] := Select[Map[Function[fn, If[MemberQ[iKGAssetKey /@ assets, iKGAssetKey[First[fn["Assets"]]]], figNumOf[fn["Id"]], None]], figNodes], IntegerQ];
    refs = DeleteDuplicates[Flatten[iKGFigureRefs /@ Select[texts, StringQ]]];
    Do[If[! MemberQ[on[], m] && KeyExistsQ[figByNum, m] && TrueQ[reshowQ] && Length[assets] < maxA,
        AppendTo[assets, First[figByNum[m]["Assets"]]]], {m, refs}];
    {assets, on[]}];

iKGWord[lang_String, key_String] := Lookup[If[lang === "ja",
  <|"Cont" -> " (\:7d9a\:304d)", "Agenda" -> "\:5168\:4f53\:306e\:6d41\:308c", "Part" -> "\:7b2c", "PartSuffix" -> "\:90e8", "Sep" -> " \:203a "|>,
  <|"Cont" -> " (cont.)", "Agenda" -> "Outline", "Part" -> "Part ", "PartSuffix" -> "", "Sep" -> " \:203a "|>], key, ""];
iKGPartLabel[lang_String, k_Integer, title_String] :=
  iKGWord[lang, "Part"] <> ToString[k] <> iKGWord[lang, "PartSuffix"] <> " " <> title;

(* \:8cc7\:7523\:304c\:5360\:3081\:308b\:884c\:6570: \:56f3 (\:4f55\:679a\:3067\:3082\:7e2e\:3081\:3066\:4e26\:3079\:308b) \:306f figLines\:3001\:8868\:306f\:884c\:6570 + \:898b\:51fa\:3057 *)
iKGTableAssetQ[a_] := AssociationQ[a] && Lookup[a, "Type", ""] === "Table";
iKGAssetLines[assets_List, figLines_Integer] :=
  If[AnyTrue[assets, ! iKGTableAssetQ[#] &], figLines, 0] +
  Total[(Length[iKGList[Lookup[#, "Rows", {}]]] + 1) & /@ Select[assets, iKGTableAssetQ]];
(* \:8868\:306e\:30bb\:30eb\:3084\:8aad\:307f\:4e0a\:3052\:306b\:4f7f\:3046\:5e73\:6587: **\:5f37\:8abf** \:3068 $\[Ellipsis]$ \:306e\:5370\:3092\:5916\:3059 *)
iKGPlain[s_String] := StringTrim[StringReplace[s, {"**" -> "", "$" -> "", "\\mathrm" -> "", "\\" -> ""}]];
iKGPlain[_] := "";
(* \:7528\:8a9e\:30df\:30cb\:8f9e\:66f8\:306e 1 \:884c: \:984c\:76ee | \:610f\:5473 (Lead > \:6700\:521d\:306e\:8981\:70b9 > \:8981\:7d04\:306e 1 \:6587) *)
iKGGlossRow[n_Association, lang_String] := Module[{m},
  m = SourceVaultKGText[n, "Lead", lang];
  If[m === "", m = First[Replace[SourceVaultKGText[n, "Points", lang], Except[{__String}] -> {""}]]];
  If[m === "", m = iKGFirstSentence[SourceVaultKGText[n, "Summary", lang], lang]];
  m = iKGPlain[m];
  If[StringLength[m] > 46, m = StringTake[m, 45] <> "\[Ellipsis]"];
  {iKGPlain[StringReplace[SourceVaultKGText[n, "Label", lang], RegularExpression["\\s+[\[LongDash]\[Dash]-]\\s+.*$"] -> ""]], m}];

SourceVaultKGOutline[kg_Association, plan_Association, OptionsPattern[]] := Module[
  {lang = Replace[OptionValue["Language"], Automatic -> Lookup[kg, "Language", "ja"]], index = iKGNodeIndex[kg],
   primary = Lookup[kg, "Language", "ja"], missing = {}, maxA = OptionValue["MaxAssetsPerSlide"],
   maxP = OptionValue["MaxPointsPerSlide"], cpl = OptionValue["CharsPerLine"], figLines = OptionValue["FigureLines"],
   maxL = OptionValue["MaxLinesPerSlide"], cps = OptionValue["CharsPerSecond"], reshowQ = TrueQ[OptionValue["ReShowFigures"]],
   slides, labelOf, agendaQ, partTitles, crumbs, contSuffix, containsParent, secIds, rootId = Lookup[kg, "Root", "root"],
   slideIds, pslides, collapsed = <||>, figNodes, figNumOf, figByNum, topOf, partNodes, partOf, slideParentOf, entryIdx,
   figUse = <||>, adjAll, inheritFor, figOfAsset, glossary, reuse = Max[0, Replace[OptionValue["FigureReuse"], Except[_Integer] -> 2]], tocQ},
  If[! IntegerQ[cpl] || cpl < 10, cpl = 40];
  contSuffix = iKGWord[lang, "Cont"];
  labelOf[id_] := If[KeyExistsQ[index, id], SourceVaultKGText[index[id], "Label", lang], ""];
  (* \:7ae0\:69cb\:9020\:306f KG \:306e Contains \:3067\:898b\:308b (\:9806\:5e8f\:6728\:306f\:9023\:7d9a\:6027\:306e\:305f\:3081\:306b\:4ed8\:3051\:66ff\:3048\:308b\:306e\:3067 Depth \:306f\:7ae0\:306e\:6df1\:3055\:3067\:306f\:306a\:3044) *)
  containsParent = Association[Map[#["To"] -> #["From"] &, Reverse[Select[Lookup[kg, "Edges", {}], #["EdgeKind"] === "Contains" &]]]];
  secIds = DeleteDuplicates[Lookup[Select[Lookup[kg, "Edges", {}], #["EdgeKind"] === "Contains" &], "From", {}]];
  (* v1.46: \:76ee\:6b21\:304b\:3089\:306e\:8a08\:753b\:306a\:3089\:3001\:7ae0\:7acb\:3066\:306f\:76ee\:6b21\:306e\:6728 (\:8a08\:753b\:304c\:89aa\:3068\:7bc0\:3092\:6e21\:3059) *)
  tocQ = Lookup[plan, "Mode", None] === "Toc";
  If[tocQ,
    containsParent = Replace[Lookup[plan, "TreeParent", <||>], Except[_Association] -> <||>];
    secIds = Replace[Lookup[plan, "TreeInternal", {}], Except[_List] -> {}]];
  (* \:56f3\:30ce\:30fc\:30c9\:306e\:756a\:53f7\:8868 (\:56f3\:8868\:756a\:53f7\:306e\:8a00\:53ca\:306e\:7167\:5408\:3068\:518d\:63b2\:306b\:4f7f\:3046) *)
  (* \:56f3\:30ce\:30fc\:30c9 = \:56f3\:306e\:8cc7\:7523\:3092\:6301\:3064\:30ce\:30fc\:30c9 (\:63a8\:6572\:3067 Kind \:304c Result \:7b49\:306b\:5909\:308f\:3063\:3066\:3044\:308b\:3053\:3068\:304c\:3042\:308b) *)
  figNodes = Select[Lookup[kg, "Nodes", {}], AnyTrue[Replace[Lookup[#, "Assets", {}], Except[_List] -> {}],
    AssociationQ[#] && MemberQ[{"NotebookFigure", "PDFFigure", "PDFImage", "DeckSlide", "Image"}, Lookup[#, "Type", ""]] &] &];
  figNumOf = Association[Map[#["Id"] -> iKGFigureNumberOf[#] &, figNodes]];
  figByNum = Association[Map[Function[f, With[{m = figNumOf[f["Id"]]}, If[IntegerQ[m], m -> f, Nothing]]], Reverse[figNodes]]];
  (* \:56f3\:306e\:7d99\:627f: \:56f3\:306e\:7121\:3044\:679a\:306b\:3001\:8fba\:3067\:7d50\:3070\:308c\:305f\:56f3 (\:7121\:3051\:308c\:3070\:540c\:3058\:7bc0\:306e\:56f3) \:3092\:518d\:63b2\:3059\:308b\:3002\:8ad6\:6587\:306e\:56f3\:306f\:679a\:6570\:304c\:5c11\:306a\:3044\:306e\:3067\:3001
     1 \:3064\:306e\:56f3\:3092\:4f55\:679a\:304b\:3067\:898b\:305b\:76f4\:3059 (32 \:56de\:306e\:3088\:3046\:306b\:56f3\:304c\:4e3b\:5f79\:306e\:679a\:306b\:3059\:308b)\:3002\:7d99\:627f\:3067\:898b\:305b\:76f4\:3059\:306e\:306f\:56f3\:3054\:3068\:306b "FigureReuse" \:56de\:307e\:3067
     (\:56f3\:81ea\:8eab\:306e\:679a\:306f\:6570\:3048\:306a\:3044)\:3002figUse = \:7d99\:627f\:3057\:305f\:56de\:6570 *)
  adjAll = Merge[Join[Map[#["From"] -> #["To"] &, Lookup[kg, "Edges", {}]], Map[#["To"] -> #["From"] &, Lookup[kg, "Edges", {}]]],
    DeleteDuplicates];
  figOfAsset[a_] := SelectFirst[figNodes, iKGAssetKey[First[#["Assets"]]] === iKGAssetKey[a] &, None];
  (* \:5b50\:30b9\:30e9\:30a4\:30c9\:304c 1 \:3064\:3060\:3051\:306e\:7bc0\:306f\:9053\:6a19\:306b\:306a\:3089\:306a\:3044 (1 \:884c\:3060\:3051\:306e\:679a\:306b\:306a\:308b) \:306e\:3067\:679a\:3092\:7573\:307f\:3001\:79d2\:306f\:6b21\:306e\:679a (\:305d\:306e\:5b50) \:3078 *)
  slideIds = Lookup[plan["Slides"], "NodeId", {}];
  pslides = Module[{out = {}, carry = 0}, Do[
    Module[{s = ps, kids = Select[Lookup[ps, "Children", {}], MemberQ[slideIds, #] &]},
      If[! tocQ && TrueQ[OptionValue["Roadmap"]] && MemberQ[secIds, s["NodeId"]] && s["NodeId"] =!= rootId &&
          Lookup[s, "Packed", {}] === {} && Length[kids] === 1 && Lookup[index[s["NodeId"]], "Assets", {}] === {},
        collapsed[s["NodeId"]] = First[kids]; carry += Lookup[s, "Seconds", 0],
        If[carry > 0, s["Seconds"] = Lookup[s, "Seconds", 0] + carry; carry = 0]; AppendTo[out, s]]],
    {ps, plan["Slides"]}]; out];
  slideIds = Lookup[pslides, "NodeId", {}];
  (* \:56f3\:306e\:7d99\:627f\:306e\:5272\:308a\:5f53\:3066: 1 \:6bb5\:76ee = \:8fba\:3067\:7d50\:3070\:308c\:305f\:56f3\:30012 \:6bb5\:76ee = \:540c\:3058\:7bc0\:306e\:56f3 (\:51fa\:73fe\:9806\:306e\:8fd1\:3044\:9806)\:3002
     \:56f3\:306e\:7121\:3044\:672c\:6587\:306e\:679a\:3060\:3051\:304c\:5bfe\:8c61 (\:7bc0\:306e\:679a\:30fb\:6839\:30fb\:8a70\:3081\:8fbc\:3093\:3060\:5b50\:306b\:56f3\:304c\:3042\:308b\:679a\:306f\:9664\:304f) *)
  inheritFor = <||>;
  If[TrueQ[OptionValue["InheritFigures"]] && figNodes =!= {},
    Module[{elig, pick},
      elig = Select[pslides, Function[ps, With[{id = ps["NodeId"]},
        id =!= rootId && ! MemberQ[secIds, id] && KeyExistsQ[index, id] &&
        Replace[Lookup[index[id], "Assets", {}], Except[_List] -> {}] === {} &&
        AllTrue[Lookup[ps, "Packed", {}], Replace[Lookup[Lookup[index, #, <||>], "Assets", {}], Except[_List] -> {}] === {} &]]]];
      pick[id_, cands_] := With[{ok = Select[cands, Lookup[figUse, #["Id"], 0] < reuse &]},
        If[ok =!= {},
          inheritFor[id] = First[ok]; figUse[First[ok]["Id"]] = Lookup[figUse, First[ok]["Id"], 0] + 1]];
      Do[With[{id = ps["NodeId"]},
          pick[id, SortBy[Select[figNodes, MemberQ[Lookup[adjAll, id, {}], #["Id"]] &], Lookup[figUse, #["Id"], 0] &]]],
        {ps, elig}];
      Do[With[{id = ps["NodeId"], n0 = index[ps["NodeId"]]},
          If[! KeyExistsQ[inheritFor, id] && Lookup[n0, "Layer", "Paper"] === "Paper" &&
              KeyExistsQ[containsParent, id] && containsParent[id] =!= rootId,
            pick[id, SortBy[Select[figNodes, Lookup[containsParent, #["Id"], None] === containsParent[id] &],
              Abs[Replace[Lookup[#, "Order", None], Except[_?NumericQ] -> 10^6] -
                Replace[Lookup[n0, "Order", None], Except[_?NumericQ] -> 0]] &]]]],
        {ps, elig}]]];
  slides = Flatten[Map[Function[s,
    Module[{n = index[s["NodeId"]], points, own, details, lead, sub, assets, cite, talk, title, budget, overflow, out, k = 0,
            secs, contSlides, children, roadmapQ, refs, onSlide, keepNums, shown, cap, rowQ, maxA1},
      If[! iKGHasLanguageQ[Lookup[n, "Label", ""], lang, primary] || ! iKGHasLanguageQ[Lookup[n, "Points", {}], lang, primary],
        AppendTo[missing, s["NodeId"]]];
      title = SourceVaultKGText[n, "Label", lang];
      own = Take[SourceVaultKGText[n, "Points", lang], UpTo[maxP]];
      details = Replace[SourceVaultKGText[n, "Details", lang], Except[_List] -> {}];
      children = Select[labelOf /@ Select[Lookup[s, "Children", {}], MemberQ[slideIds, #] &], # =!= "" &];
      (* \:7bc0\:30b9\:30e9\:30a4\:30c9 = \:9053\:6a19: \:305d\:306e\:7bc0\:3067\:30b9\:30e9\:30a4\:30c9\:306b\:306a\:308b\:5b50\:306e\:984c\:76ee (2 \:3064\:4ee5\:4e0a) \:3092\:8981\:70b9\:306b\:3057\:3066\:3001\:90e8\:306e\:4e2d\:306e\:4f4d\:7f6e\:3065\:3051\:3092\:898b\:305b\:308b\:3002
         LLM \:304c\:7bc0\:306b\:4ed8\:3051\:305f\:8981\:70b9\:306f\:539f\:7a3f\:3078\:3002\:7bc0 = KG \:3067 Contains \:306e\:5b50\:3092\:6301\:3064\:30ce\:30fc\:30c9 (\:63a8\:6572\:3067 Kind \:304c\:5909\:308f\:3063\:3066\:3044\:3066\:3082\:3088\:3044) *)
      roadmapQ = TrueQ[OptionValue["Roadmap"]] && MemberQ[secIds, s["NodeId"]] && s["NodeId"] =!= rootId && Length[children] >= 2;
      (* v1.46: \:76ee\:6b21\:306e\:7bc0 (\:6839\:3092\:542b\:3080) \:306f\:5b50\:306e\:4e00\:884c\:8981\:7d04\:3092\:4e26\:3079\:308b: \:958b\:3044\:305f\:7bc0\:306f\:9053\:6a19\:3001\:958b\:304b\:306a\:3044\:7bc0\:306f\:6982\:8981\:306e 1 \:679a\:3001\:6839\:306f\:5168\:4f53\:306e\:6d41\:308c *)
      If[tocQ && MemberQ[secIds, s["NodeId"]] && Lookup[s, "AllChildren", {}] =!= {},
        roadmapQ = True;
        children = Select[Map[iKGOneLiner[Lookup[index, #, <||>], lang, primary] &, s["AllChildren"]], # =!= "" &]];
      points = If[roadmapQ, Take[children, UpTo[maxP]], own];
      If[roadmapQ, details = {}];
      (* \:5c0e\:5165\:6587: \:30ce\:30fc\:30c9\:306e Lead\:3001\:7121\:3051\:308c\:3070 Summary \:306e\:6700\:521d\:306e 1 \:6587 (\:30b9\:30e9\:30a4\:30c9\:3060\:3051\:898b\:3066\:3082\:4f55\:306e\:8a71\:304b\:5206\:304b\:308b\:3088\:3046\:306b) *)
      lead = SourceVaultKGText[n, "Lead", lang];
      If[lead === "" && s["NodeId"] =!= rootId, lead = iKGFirstSentence[SourceVaultKGText[n, "Summary", lang], lang]];
      If[tocQ && lead === "" && s["NodeId"] === rootId,
        lead = With[{gi = SourceVaultKGText[n, "Gist", lang]}, If[gi =!= "", gi, iKGFirstSentence[SourceVaultKGText[n, "Summary", lang], lang]]]];
      (* v1.48: \:610f\:5473\:4ed8\:3051\:306e\:5f79\:5272 (Role = \:3053\:306e\:679a\:304c\:306a\:305c\:3053\:3053\:306b\:3042\:308b\:304b) \:304c\:3042\:308c\:3070\:5c0e\:5165\:6587\:306b\:3059\:308b *)
      With[{ro = SourceVaultKGText[n, "Role", lang]}, If[ro =!= "", lead = ro]];
      If[lead =!= "" && points =!= {} && StringTrim[lead, "\:3002" | "."] === StringTrim[First[points], "\:3002" | "."], lead = ""];
      (* \:8a70\:3081\:8fbc\:3093\:3060\:5b50: \:30e9\:30d9\:30eb + 1 \:884c (Lead \:304c\:3042\:308c\:3070\:305d\:308c\:3001\:7121\:3051\:308c\:3070\:8981\:70b9 2 \:3064\:307e\:3067) *)
      sub = Map[Function[p, With[{m = index[p]},
        <|"NodeId" -> p, "Label" -> SourceVaultKGText[m, "Label", lang],
          "Points" -> With[{ld = SourceVaultKGText[m, "Lead", lang]},
            If[ld =!= "", {ld}, Take[SourceVaultKGText[m, "Points", lang], UpTo[2]]]]|>]], Lookup[s, "Packed", {}]];
      If[points === {} && MemberQ[secIds, s["NodeId"]] && s["NodeId"] =!= rootId, points = Take[children, UpTo[maxP]]];
      If[points === {} && sub === {} && lead === "" && SourceVaultKGText[n, "Summary", lang] =!= "",
        points = {SourceVaultKGText[n, "Summary", lang]}];
      (* v1.42: \:56f3\:3092\:6a2a\:306b\:4e26\:3079\:308b\:679a (FigureLayout "Row") \:306f\:56f3\:3092 4 \:3064\:307e\:3067\:8f09\:305b\:308b *)
      rowQ = Lookup[n, "FigureLayout", None] === "Row";
      maxA1 = If[rowQ, Max[maxA, 4], maxA];
      (* \:6a2a\:4e26\:3073\:306e\:679a\:306f\:5229\:7528\:8005\:304c\:9078\:3093\:3060\:56f3\:3060\:3051\:3092\:4e26\:3079\:308b (\:8a70\:3081\:8fbc\:3093\:3060\:5b50\:306e\:56f3\:3092\:8db3\:3059\:3068\:540c\:3058\:5199\:771f\:304c\:91cd\:306a\:3063\:305f)\:3002\:540c\:3058\:56f3\:306f 1 \:56de *)
      assets = Take[DeleteDuplicatesBy[If[rowQ, Lookup[n, "Assets", {}],
        Join[Lookup[n, "Assets", {}], Flatten[Lookup[index[#], "Assets", {}] & /@ Lookup[s, "Packed", {}], 1]]],
        If[StringQ[Lookup[#, "Ref", None]] && #["Ref"] =!= "", iKGAssetKey[#], #] &], UpTo[maxA1]];
      If[assets === {} && TrueQ[OptionValue["InheritFigures"]] && ! roadmapQ && s["NodeId"] =!= rootId,
        With[{fn = Lookup[inheritFor, s["NodeId"], None]}, If[AssociationQ[fn], assets = {First[fn["Assets"]]}]]];
      (* v1.46: \:958b\:304b\:306a\:3044\:7bc0 (\:6982\:8981\:306e 1 \:679a) \:306b\:306f\:90e8\:5206\:6728\:3067\:3044\:3061\:3070\:3093\:5927\:4e8b\:306a\:56f3\:3092 1 \:3064 *)
      If[tocQ && assets === {} && StringQ[Lookup[s, "Figure", None]] && KeyExistsQ[index, s["Figure"]] && s["NodeId"] =!= rootId,
        assets = Take[Select[Replace[Lookup[index[s["Figure"]], "Assets", {}], Except[_List] -> {}], AssociationQ], UpTo[1]]];
      (* \:30b9\:30e9\:30a4\:30c9\:306f\:305d\:306e\:679a\:306b\:3042\:308b\:56f3\:8868\:3057\:304b\:6307\:305b\:306a\:3044: \:8a00\:53ca\:3055\:308c\:305f\:56f3\:304c\:3053\:306e\:679a\:306b\:7121\:3051\:308c\:3070\:518d\:63b2 (\:67a0\:304c\:3042\:308c\:3070)\:3001
         \:7121\:7406\:306a\:3089\:62ec\:5f27\:3064\:304d\:306e\:8a00\:53ca\:3092\:6d88\:3059\:3002\:8868\:306f\:8cc7\:7523\:306b\:306a\:3089\:306a\:3044\:306e\:3067\:8a00\:53ca\:3092\:6d88\:3059 *)
      {assets, keepNums} = iKGResolveFigs[Join[{lead}, points, details, Flatten[Lookup[sub, "Points", {}]]],
        assets, figNodes, figNumOf, figByNum, maxA1, reshowQ];
      lead = iKGStripFigureRefs[lead, keepNums];
      points = iKGStripFigureRefs[#, keepNums] & /@ points;
      details = iKGStripFigureRefs[#, keepNums] & /@ details;
      sub = Map[Append[#, "Points" -> (iKGStripFigureRefs[#, keepNums] & /@ #["Points"])] &, sub];
      budget = Max[3, maxL - iKGAssetLines[assets, figLines]];
      (* \:56f3\:306e\:3042\:308b\:679a\:306f\:81ea\:8eab\:306e\:8981\:70b9\:3092 1 \:884c\:307e\:3067\:524a\:3063\:3066\:3088\:3044 (\:56f3\:304c\:4e3b\:5f79) *)
      {points, details, sub, overflow} = iKGFitLines[lead, points, details, sub, budget, cpl, If[assets =!= {}, 1, 2]];
      cite = SourceVaultKGText[n, "Cite", lang];
      If[cite === "", cite = FirstCase[Join[SourceVaultKGText[index[#], "Cite", lang] & /@ Lookup[sub, "NodeId", {}],
        Map[Function[a, With[{f = SelectFirst[figNodes, iKGAssetKey[First[#["Assets"]]] === iKGAssetKey[a] &, None]},
          If[AssociationQ[f], SourceVaultKGText[f, "Cite", lang], ""]]], assets]], c_String /; c =!= "", ""]];
      (* \:539f\:7a3f\:306f\:7b87\:6761\:66f8\:304d\:3068\:540c\:3058\:9806\:306b\:5bfe\:5fdc\:3055\:305b\:308b (\:5192\:982d\:306e\:6982\:8981\:8aac\:660e\:304c\:7b87\:6761\:66f8\:304d\:3068\:98df\:3044\:9055\:3046\:3068\:3001\:8074\:304d\:624b\:306f\:30c8\:30fc\:30af\:3068
         \:30b9\:30e9\:30a4\:30c9\:306e\:3069\:3061\:3089\:3092\:8ffd\:3048\:3070\:3088\:3044\:304b\:8ff7\:3046): \:81ea\:8eab\:306e\:8981\:70b9 \[RightArrow] \:8a70\:3081\:8fbc\:3093\:3060\:5b50\:306e\:9806\:3002\:9577\:3055\:306f\:79d2\:6570\:3068\:884c\:6570\:3067\:6291\:3048\:308b *)
      talk = If[roadmapQ,
        If[lang === "ja", "\:3053\:306e\:90e8\:3067\:306f\:3001" <> StringRiffle[points, "\:3001"] <> " \:306e\:9806\:306b\:898b\:3066\:3044\:304d\:307e\:3059\:3002",
          "In this part we look at " <> StringRiffle[points, ", "] <> "."] <>
          With[{s0 = SourceVaultKGText[n, "Summary", lang]}, If[s0 === "", "", " " <> s0]],
        iKGNodeTalk[n, Length[points], lang]];
      If[tocQ && roadmapQ,
        talk = Which[
          s["NodeId"] === rootId, iKGAgendaTalk[points, lang],
          (* v1.48: \:6982\:8981\:306e\:679a\:306f\:5b50\:306e\:984c\:76ee\:3092\:8aad\:307f\:4e0a\:3052\:305a\:3001\:5f79\:5272\:3068\:8981\:7d04\:3067\:8a71\:3059 (\:984c\:76ee\:306e\:8aad\:307f\:4e0a\:3052\:306f\:5217\:6319\:306b\:306a\:308a\:3001\:5f0f\:306e\:984c\:76ee\:306f\:300c\:3053\:306e\:5f0f\:300d\:306b\:306a\:308b) *)
          ! TrueQ[Lookup[s, "Expanded", False]],
            With[{ro = SourceVaultKGText[n, "Role", lang], s0 = SourceVaultKGText[n, "Summary", lang]},
              Which[ro =!= "" || s0 =!= "", StringRiffle[Select[{ro, s0}, # =!= "" &], " "],
                lang === "ja", title <> "\:306e\:8981\:70b9\:3092\:4e00\:679a\:306b\:307e\:3068\:3081\:307e\:3057\:305f\:3002",
                True, "This slide sums up " <> title <> ". "]],
          True, talk]];
      talk = StringRiffle[Select[Prepend[Map[iKGNodeTalk[index[#["NodeId"]], Length[#["Points"]], lang] &, sub], talk], # =!= "" &], " "];
      If[talk === "", talk = iKGTalkFallback[Join[points, Flatten[Lookup[sub, "Points", {}]]], title, lang]];
      talk = iKGStripFigureRefs[talk, keepNums];
      (* \:7d9a\:304d\:30b9\:30e9\:30a4\:30c9: \:53ce\:307e\:3089\:306a\:304b\:3063\:305f\:5b50\:3092\:540c\:3058\:984c\:76ee + (\:7d9a\:304d) \:3067\:5f8c\:308d\:306b\:4e26\:3079\:308b\:3002\:79d2\:306f\:5747\:7b49\:306b\:5206\:3051\:308b\:3002
         \:3042\:3075\:308c\:305f\:306e\:304c\:5b50 1 \:3064\:3060\:3051\:306a\:3089 (\:7d9a\:304d) \:306b\:305b\:305a\:3001\:305d\:306e\:5b50\:81ea\:8eab\:306e\:30b9\:30e9\:30a4\:30c9\:306b\:6607\:683c\:3059\:308b (\:9805\:76ee 1 \:3064\:3060\:3051\:306e\:679a\:3092\:4f5c\:3089\:306a\:3044) *)
      contSlides = {};
      While[overflow =!= {} && k < 8,
        k++;
        Module[{p2, d2, s2, o2, t2, a2 = {}, keep2, lead2 = "", title2, cite2 = "", node2, contQ, m2, r2},
          {p2, d2, s2, o2} = iKGFitLines["", {}, {}, overflow, Max[3, maxL], cpl];
          contQ = ! (p2 === {} && Length[s2] === 1 && KeyExistsQ[index, First[s2]["NodeId"]]);
          If[contQ,
            title2 = title <> contSuffix; node2 = s["NodeId"];
            cite2 = FirstCase[SourceVaultKGText[index[#], "Cite", lang] & /@ Lookup[s2, "NodeId", {}], c_String /; c =!= "", ""],
            (* \:6607\:683c: \:8a70\:3081\:8fbc\:307f\:3092\:89e3\:3044\:3066\:5b50\:30ce\:30fc\:30c9\:306e\:30b9\:30e9\:30a4\:30c9\:306b\:3059\:308b *)
            m2 = index[First[s2]["NodeId"]]; node2 = Lookup[m2, "Id", First[s2]["NodeId"]];
            title2 = SourceVaultKGText[m2, "Label", lang];
            lead2 = SourceVaultKGText[m2, "Lead", lang];
            If[lead2 === "", lead2 = iKGFirstSentence[SourceVaultKGText[m2, "Summary", lang], lang]];
            p2 = Take[Replace[SourceVaultKGText[m2, "Points", lang], Except[_List] -> {}], UpTo[maxP]];
            If[p2 === {}, p2 = First[s2]["Points"]];
            d2 = Replace[SourceVaultKGText[m2, "Details", lang], Except[_List] -> {}];
            If[lead2 =!= "" && p2 =!= {} && StringTrim[lead2, "\:3002" | "."] === StringTrim[First[p2], "\:3002" | "."], lead2 = ""];
            a2 = Take[Replace[Lookup[m2, "Assets", {}], Except[_List] -> {}], UpTo[maxA]];
            cite2 = SourceVaultKGText[m2, "Cite", lang]; s2 = {}];
          {a2, keep2} = iKGResolveFigs[Join[{lead2}, p2, d2, Flatten[Lookup[s2, "Points", {}]]], a2, figNodes, figNumOf, figByNum, maxA, reshowQ];
          lead2 = iKGStripFigureRefs[lead2, keep2];
          p2 = iKGStripFigureRefs[#, keep2] & /@ p2;
          d2 = iKGStripFigureRefs[#, keep2] & /@ d2;
          s2 = Map[Append[#, "Points" -> (iKGStripFigureRefs[#, keep2] & /@ #["Points"])] &, s2];
          r2 = iKGFitLines[lead2, p2, d2, s2, Max[3, maxL - iKGAssetLines[a2, figLines]], cpl, If[a2 =!= {}, 1, 2]];
          p2 = r2[[1]]; d2 = r2[[2]]; s2 = r2[[3]]; o2 = Join[r2[[4]], o2];
          t2 = If[contQ,
            StringRiffle[Select[Map[iKGNodeTalk[index[#["NodeId"]], Length[#["Points"]], lang] &, s2], # =!= "" &], " "],
            iKGNodeTalk[index[node2], Length[p2], lang]];
          If[t2 === "", t2 = iKGTalkFallback[Join[p2, Flatten[Lookup[s2, "Points", {}]]], title2, lang]];
          AppendTo[contSlides, <|"NodeId" -> node2, "Title" -> title2, "Lead" -> lead2, "Points" -> p2, "Details" -> d2, "Sub" -> s2,
            "Assets" -> a2, "Cite" -> cite2, "Talk" -> iKGStripFigureRefs[t2, keep2],
            "Seconds" -> 0, "Flags" -> s["Flags"], "Depth" -> s["Depth"], "Kind" -> Lookup[n, "Kind", ""], "Continuation" -> contQ|>];
          overflow = o2]];
      out = Prepend[contSlides, <|"NodeId" -> s["NodeId"], "Title" -> title, "Lead" -> lead, "Points" -> points, "Details" -> details,
        "Sub" -> sub, "Assets" -> assets, "Cite" -> cite, "Talk" -> talk, "Seconds" -> Lookup[s, "Seconds", 25], "Flags" -> s["Flags"],
        "Depth" -> s["Depth"], "Kind" -> n["Kind"], "Continuation" -> False, "FigureLayout" -> If[rowQ, "Row", None]|>];
      If[Length[out] > 1,
        secs = Quotient[Lookup[s, "Seconds", 25], Length[out]];
        out = MapIndexed[Append[#1, "Seconds" -> secs + If[First[#2] === 1, Lookup[s, "Seconds", 25] - secs * Length[out], 0]] &, out]];
      (* \:539f\:7a3f\:306e\:9577\:3055\:306f\:3001\:7d9a\:304d\:306b\:5206\:3051\:305f\:3042\:3068\:306e 1 \:679a\:3042\:305f\:308a\:306e\:79d2\:6570\:3068\:884c\:6570\:3067\:6291\:3048\:308b
         (v1.26 \:306f\:5206\:3051\:308b\:524d\:306e\:79d2\:6570\:3067\:4e0a\:9650\:3092\:53d6\:3063\:3066\:3044\:305f\:306e\:3067\:3001\:4e00\:5ea6\:3082\:5207\:308a\:8a70\:3081\:3089\:308c\:306a\:304b\:3063\:305f) *)
      out = Map[Function[sl, Append[sl, "Talk" -> iKGCapTalk[sl["Talk"], sl["Seconds"], lang,
        iKGSlideLines[sl["Lead"], sl["Points"], sl["Details"], sl["Sub"], cpl] + 2, cps]]], out];
      out]], pslides], 1];
  (* \:7528\:8a9e\:30df\:30cb\:8f9e\:66f8: \:56f3\:3082\:5b50\:3082\:7121\:3044\:5468\:8fba\:77e5\:8b58\:306e\:679a\:304c\:7d9a\:304f\:3068\:3053\:308d\:306f\:30011 \:679a\:305a\:3064\:6982\:5ff5\:30b9\:30e9\:30a4\:30c9\:306b\:305b\:305a\:8868\:306b\:307e\:3068\:3081\:308b
     (\:8a08\:7b97\:3068\:81ea\:713633: \:5468\:8fba\:77e5\:8b58\:306e\:6587\:5b57\:3060\:3051\:306e\:679a\:304c 16 \:679a\:7d9a\:304d\:3001\:8ad6\:6587\:306e\:56f3\:304c\:51fa\:308b\:524d\:306b\:679a\:6570\:3092\:4f7f\:3044\:5207\:3063\:305f)\:3002
     \:91cd\:8981\:5ea6 0.8 \:4ee5\:4e0a\:306e\:5468\:8fba\:77e5\:8b58\:306f 1 \:679a\:306e\:307e\:307e\:3002\:8868\:306f "GlossaryRows" \:884c\:305a\:3064 *)
  glossary = Replace[OptionValue["Glossary"], Automatic -> True];
  If[TrueQ[glossary],
    Module[{eligible, runs, out = {}, rowsMax = Max[2, OptionValue["GlossaryRows"]]},
      eligible[sl_] := ! TrueQ[sl["Continuation"]] && sl["Assets"] === {} && sl["Sub"] === {} &&
        KeyExistsQ[index, sl["NodeId"]] && Lookup[index[sl["NodeId"]], "Layer", ""] === "Background" &&
        Lookup[index[sl["NodeId"]], "Importance", 0.5] < 0.8 && ! MemberQ[secIds, sl["NodeId"]];
      runs = Split[slides, eligible[#1] && eligible[#2] &];
      Do[
        If[Length[run] >= 2 && eligible[First[run]],
          MapIndexed[Function[{chunk, ci},
            Module[{rows = iKGGlossRow[index[#["NodeId"]], lang] & /@ chunk, secs = Total[Lookup[chunk, "Seconds", 0]], talk},
              talk = If[lang === "ja",
                "\:3053\:3053\:3067\:3001\:3053\:306e\:5148\:306b\:51fa\:3066\:304f\:308b\:8a00\:8449\:3092\:307e\:3068\:3081\:3066\:304a\:304d\:307e\:3059\:3002" <> StringJoin[Map[#[[1]] <> "\:306f\:3001" <> StringTrim[#[[2]], "\:3002" | "\[Ellipsis]"] <> "\:3002" &, rows]],
                "Here are the terms we will need. " <> StringRiffle[Map[#[[1]] <> ": " <> StringTrim[#[[2]], "." | "\[Ellipsis]"] <> "." &, rows], " "]];
              AppendTo[out, <|"NodeId" -> First[chunk]["NodeId"],
                "Title" -> If[lang === "ja", "\:7528\:8a9e\:30df\:30cb\:8f9e\:66f8", "Glossary"] <> If[First[ci] > 1, contSuffix, ""],
                "Lead" -> "", "Points" -> {}, "Details" -> {}, "Sub" -> {},
                "Assets" -> {<|"Type" -> "Table", "Rows" -> Prepend[rows, If[lang === "ja", {"\:7528\:8a9e", "\:610f\:5473"}, {"Term", "Meaning"}]]|>},
                "Cite" -> "", "Talk" -> iKGCapTalk[talk, secs, lang, Length[rows] + 2, cps], "Seconds" -> secs,
                "Flags" -> First[chunk]["Flags"], "Depth" -> First[chunk]["Depth"], "Kind" -> "Glossary",
                "Continuation" -> False, "Merged" -> Lookup[chunk, "NodeId"]|>]]],
            With[{ch = Partition[run, UpTo[rowsMax]]},
              (* \:6700\:5f8c\:306e 1 \:884c\:3060\:3051\:306e\:8868\:306f\:4f5c\:3089\:305a\:524d\:306e\:8868\:306b\:8db3\:3059 *)
              If[Length[ch] >= 2 && Length[Last[ch]] === 1, Append[Drop[ch, -2], Join[ch[[-2]], ch[[-1]]]], ch]]],
          out = Join[out, run]],
        {run, runs}];
      slides = out]];
  (* \:90e8 = \:6839\:306e\:76f4\:4e0b (Contains) \:306e\:7bc0\:306e\:3046\:3061\:3001\:305d\:306e\:90e8\:5206\:6728\:306b\:30b9\:30e9\:30a4\:30c9\:304c\:3042\:308b\:3082\:306e (\:7bc0\:81ea\:8eab\:304c\:7573\:307e\:308c\:3066\:3044\:3066\:3082\:3088\:3044)\:3002
     \:5404\:30b9\:30e9\:30a4\:30c9\:306e\:90e8\:306f Contains \:306e\:89aa\:3092\:6839\:306e\:76f4\:4e0b\:307e\:3067\:8fbf\:3063\:3066\:6c7a\:3081\:3001\:89aa\:30b9\:30e9\:30a4\:30c9\:306f\:30b9\:30e9\:30a4\:30c9\:306b\:5f53\:305f\:308b\:307e\:3067\:8fbf\:308b *)
  topOf[id_] := Module[{x = id, k = 0}, If[! KeyExistsQ[containsParent, x] || x === rootId, Return[None]];
    While[k < 50 && KeyExistsQ[containsParent, x] && containsParent[x] =!= rootId, x = containsParent[x]; k++];
    If[KeyExistsQ[containsParent, x] && containsParent[x] === rootId, x, None]];
  partNodes = DeleteDuplicates[Select[Map[topOf, Lookup[Select[slides, ! TrueQ[#["Continuation"]] && #["NodeId"] =!= rootId &], "NodeId", {}]],
    # =!= None && MemberQ[secIds, #] &]];
  partTitles = labelOf /@ partNodes;
  partOf[id_] := With[{t = topOf[id]}, If[MemberQ[partNodes, t], t, None]];
  slideParentOf[id_] := Module[{x = Lookup[containsParent, id, None], k = 0},
    While[k < 50 && x =!= None && x =!= rootId && ! MemberQ[slideIds, x], x = Lookup[containsParent, x, None]; k++];
    If[x === None || x === rootId, None, x]];
  crumbs = Map[Function[sl, Module[{id = sl["NodeId"], part, k, parent},
    part = partOf[id];
    Which[
      ! TrueQ[OptionValue["Crumbs"]] || part === None, "",
      (* v1.46 \:76ee\:6b21: \:958b\:3044\:305f\:7ae0\:30fb\:7bc0\:306f\:81ea\:5206\:306e\:679a\:3092\:6301\:305f\:306a\:3044\:306e\:3067\:3001\:90e8\:304b\:3089\:76f4\:8fd1 2 \:6bb5\:306e\:898b\:51fa\:3057\:3092\:30d1\:30f3\:304f\:305a\:306b\:51fa\:3059 *)
      tocQ && id =!= part,
        k = FirstPosition[partNodes, part][[1]];
        Module[{x = Lookup[containsParent, id, None], chain = {}, n = 0},
          While[n < 50 && x =!= None && x =!= part && x =!= rootId, PrependTo[chain, x]; x = Lookup[containsParent, x, None]; n++];
          iKGPartLabel[lang, k, labelOf[part]] <> StringJoin[Map[iKGWord[lang, "Sep"] <> labelOf[#] &, Take[chain, -Min[2, Length[chain]]]]]],
      True,
        k = FirstPosition[partNodes, part][[1]];
        parent = slideParentOf[id];
        If[id === part || parent === None || parent === part,
          iKGPartLabel[lang, k, labelOf[part]],
          iKGPartLabel[lang, k, labelOf[part]] <> iKGWord[lang, "Sep"] <> labelOf[parent]]]]], slides];
  slides = MapThread[Append[#1, "Crumb" -> #2] &, {slides, crumbs}];
  (* \:90e8\:306e\:5165\:53e3 (\:305d\:306e\:90e8\:306e\:6700\:521d\:306e\:679a) \:306b\:306f\:539f\:7a3f\:306b\:6a4b\:6e21\:3057\:3092\:8db3\:3059\:3002\:7d9a\:304d\:30b9\:30e9\:30a4\:30c9\:306b\:3082\:4e00\:8a00 *)
  entryIdx = Map[Function[p, FirstPosition[slides, sl_ /; partOf[sl["NodeId"]] === p && ! TrueQ[sl["Continuation"]], {0}, {1}][[1]]], partNodes];
  slides = MapIndexed[Function[{sl, ii}, With[{i = First[ii]},
    Which[
      MemberQ[entryIdx, i],
        Append[sl, "Talk" -> With[{k = FirstPosition[entryIdx, i][[1]]}, If[lang === "ja",
          "\:3053\:3053\:304b\:3089\:7b2c" <> ToString[k] <> "\:90e8\:300c" <> labelOf[partNodes[[k]]] <> "\:300d\:306b\:5165\:308a\:307e\:3059\:3002",
          "We now turn to Part " <> ToString[k] <> ", " <> labelOf[partNodes[[k]]] <> ". "]] <> sl["Talk"]],
      TrueQ[sl["Continuation"]],
        Append[sl, "Talk" -> If[lang === "ja", "\:7d9a\:304d\:3067\:3059\:3002", "Continued. "] <> sl["Talk"]],
      True, sl]]], slides];
  (* v1.48: \:679a\:3068\:679a\:306e\:3064\:306a\:304e\:30fb\:610f\:5473\:4ed8\:3051\:30fb\:521d\:51fa\:306e\:7528\:8a9e (iKGLinkSlides) *)
  slides = iKGLinkSlides[slides, index, containsParent, rootId, entryIdx, lang, tocQ];
  (* \:76ee\:6b21\:30b9\:30e9\:30a4\:30c9: \:90e8\:304c 3 \:3064\:4ee5\:4e0a\:306a\:3089\:6839\:306e\:76f4\:5f8c\:306b\:5168\:4f53\:306e\:6d41\:308c\:3092 1 \:679a (\:91cd\:8981\:5ea6 0.5 \:4ee5\:4e0a\:306e\:90e8\:3060\:3051\:3001\:6700\:5927 MaxPointsPerSlide \:884c) *)
  agendaQ = Replace[OptionValue["Agenda"], Automatic :> ! tocQ && Length[partNodes] >= 3];
  If[TrueQ[agendaQ] && partNodes =!= {} && Length[slides] >= 1,
    (* v1.44: \:5404\:90e8\:306e\:4e00\:884c\:8981\:7d04 (Gist\:3002\:968e\:5c64\:5316\:304c\:90e8\:5206\:6728\:5168\:4f53\:3092\:4e00\:884c\:3067\:66f8\:3044\:305f\:3082\:306e) \:3092\:4e26\:3079\:308b\:3002\:7121\:3044\:90e8\:306f\:984c\:76ee *)
    With[{titles = partTitles, gists = Map[iKGPartGist[index[#], labelOf[#], lang, primary] &, partNodes],
        allGist = AllTrue[partNodes, iKGHasGistQ[index[#], lang, primary] &]},
    With[{rows = Module[{lab = MapIndexed[{First[#2], #1} &, gists], keep},
        keep = Select[lab, Lookup[index[partNodes[[#[[1]]]]], "Importance", 0.5] >= 0.5 &];
        If[keep === {}, keep = lab];
        If[Length[keep] > maxP, Append[Take[keep, maxP - 1], {0, "\[Ellipsis]"}], keep]]},
      slides = Insert[slides, <|"NodeId" -> "agenda", "Title" -> iKGWord[lang, "Agenda"], "Lead" -> "",
        "Points" -> Map[If[#[[1]] === 0, #[[2]], iKGPartLabel[lang, #[[1]], #[[2]]]] &, rows], "Details" -> {}, "Sub" -> {}, "Assets" -> {}, "Cite" -> "",
        "Talk" -> If[allGist,
          If[lang === "ja", "\:672c\:65e5\:306f " <> ToString[Length[gists]] <> " \:90e8\:306b\:5206\:3051\:3066\:304a\:8a71\:3057\:3057\:307e\:3059\:3002" <>
              StringJoin[MapIndexed["\:7b2c" <> ToString[First[#2]] <> "\:90e8\:3067\:306f\:3001" <> StringTrim[#1, "\:3002"] <> "\:3092\:6271\:3044\:307e\:3059\:3002" &, gists]],
            "The talk has " <> ToString[Length[gists]] <> " parts. " <>
              StringJoin[MapIndexed["Part " <> ToString[First[#2]] <> " covers " <> StringTrim[#1, "."] <> ". " &, gists]]],
        If[lang === "ja",
          "\:672c\:65e5\:306f " <> ToString[Length[titles]] <> " \:90e8\:69cb\:6210\:3067\:3059\:3002" <> StringRiffle[titles, "\:3001"] <> " \:306e\:9806\:306b\:9032\:3081\:307e\:3059\:3002",
          "The talk has " <> ToString[Length[titles]] <> " parts: " <> StringRiffle[titles, ", "] <> "."]],
        "Seconds" -> 20, "Flags" -> {}, "Depth" -> 1, "Kind" -> "Agenda", "Continuation" -> False, "Crumb" -> ""|>, 2]]]];
  <|"ObjectClass" -> "SourceVaultKGOutline", "GraphId" -> Lookup[kg, "GraphId", ""],
    "Title" -> SourceVaultKGText[<|"Label" -> Lookup[kg, "Title", ""], "PrimaryLanguage" -> primary|>, "Label", lang],
    "Language" -> lang, "Slides" -> slides, "MissingLanguage" -> DeleteDuplicates[missing],
    "Parts" -> partTitles, "Agenda" -> TrueQ[agendaQ] && partNodes =!= {}, "Collapsed" -> Keys[collapsed],
    "Glossary" -> Flatten[Lookup[Select[slides, KeyExistsQ[#, "Merged"] &], "Merged", {}]],
    "FigureUse" -> figUse,
    "TotalSeconds" -> Lookup[plan, "TotalSeconds", 0]|>];

(* ---- v1.48: \:679a\:3068\:679a\:306e\:3064\:306a\:304e\:3068\:610f\:5473\:4ed8\:3051 ----
   \:540c\:3058\:89aa\:306e\:7d9a\:304d\:306e\:679a (Continue) \:306f\:539f\:7a3f\:3092\:8a71\:984c\:8ee2\:63db\:306e\:8a9e (\:3053\:3053\:3067\:306f\:30fb\:3055\:3066) \:3067\:59cb\:3081\:306a\:3044\:3002\:89aa\:304c\:5207\:308a\:66ff\:308f\:308a\:3001\:81ea\:5206\:306e\:679a\:3092\:6301\:305f\:306a\:3044\:65b0\:3057\:3044
   \:898b\:51fa\:3057 (\:7ae0\:30fb\:7bc0) \:306b\:5165\:308b\:679a (Shift) \:306f\:305d\:306e\:898b\:51fa\:3057\:3092\:544a\:3052\:308b\:3002\:4e0a\:306e\:6bb5\:306e\:6b21\:306e\:8a71\:3078\:623b\:308b\:679a (Return) \:306f\:8ee2\:63db\:306e\:8a9e\:3060\:3051\:5916\:3059\:3002\:90e8\:306e\:5165\:53e3 (Part)
   \:3068\:7d9a\:304d (None) \:306f\:305d\:306e\:307e\:307e\:3002\:610f\:5473\:4ed8\:3051 (SlideGraphNarrate) \:306e\:3064\:306a\:304e (Bridge) \:306f\:3001\:8a18\:9332\:3057\:305f\:524d\:306e\:679a (BridgeAfter) \:304c\:4eca\:306e\:524d\:306e\:679a\:3068
   \:540c\:3058\:3068\:304d\:3060\:3051\:539f\:7a3f\:306e\:5192\:982d\:306b\:4f7f\:3046\:3002\:521d\:3081\:3066\:51fa\:308b\:7528\:8a9e (Terms) \:306f\:679a\:306e\:4e0b\:306b\:4e00\:884c (Notes) \:3068\:539f\:7a3f\:306e\:6700\:5f8c\:306b\:4e00\:8a00\:3002\:540c\:3058\:7528\:8a9e\:306f\:6700\:521d\:306e 1 \:56de\:3060\:3051 *)
$kgSwitchWordsJa = {"\:3053\:3053\:3067\:306f\:3001", "\:3053\:3053\:3067\:306f", "\:3055\:3066\:3001", "\:305d\:308c\:3067\:306f\:3001", "\:3067\:306f\:3001"};
iKGStripSwitch[t_String, lang_] := Module[{u = StringTrim[t]},
  If[lang === "ja",
    Do[If[StringStartsQ[u, w], u = StringTrim[StringDrop[u, StringLength[w]]]; Break[]], {w, $kgSwitchWordsJa}],
    u = StringReplace[u, StartOfString ~~ ("Here we " | "Here, we ") -> "We ", 1]];
  u];
iKGStripSwitch[t_, _] := t;
iKGHeadIntro[h_Association, lang_] := With[{l = SourceVaultKGText[h, "Label", lang], g = SourceVaultKGText[h, "Gist", lang]},
  If[lang === "ja",
    "\:6b21\:306f\:300c" <> l <> "\:300d\:3067\:3059\:3002" <> If[g =!= "", StringTrim[g, "\:3002"] <> "\:3092\:898b\:3066\:3044\:304d\:307e\:3059\:3002", ""],
    "Next: " <> l <> ". " <> If[g =!= "", StringTrim[g, "."] <> ". ", ""]]];
iKGHeadIntro[_, _] := "";
iKGLinkSlides[slides_List, index_Association, cpar_Association, rootId_, entryIdx_List, lang_, tocQ_] := Module[
  {out = {}, prev = None, explained = <||>, anc, shown},
  shown = Association[Thread[Select[Lookup[slides, "NodeId", {}], StringQ] -> True]];
  anc[x_] := Module[{p = Lookup[cpar, x, None], o = {}, k = 0},
    While[p =!= None && p =!= rootId && k < 50, AppendTo[o, p]; p = Lookup[cpar, p, None]; k++]; o];
  Do[Module[{sl = slides[[i]], x, n, talk, tr, heads = {}, br, after, terms, notes = {}, glosses = {}, skipQ},
      x = Lookup[sl, "NodeId", None]; n = Replace[Lookup[index, x, <||>], Except[_Association] -> <||>];
      talk = Replace[Lookup[sl, "Talk", ""], Except[_String] -> ""];
      skipQ = MemberQ[{"Agenda", "Glossary"}, Lookup[sl, "Kind", ""]];
      tr = Which[
        TrueQ[Lookup[sl, "Continuation", False]] || skipQ || x === rootId || prev === None, "None",
        MemberQ[entryIdx, i], "Part",
        Lookup[cpar, x, None] === prev || Lookup[cpar, x, None] === Lookup[cpar, prev, None], "Continue",
        True,
          heads = Select[Reverse[anc[x]], ! MemberQ[Append[anc[prev], prev], #] && ! KeyExistsQ[shown, #] &];
          If[TrueQ[tocQ] && heads =!= {}, "Shift", "Return"]];
      br = SourceVaultKGText[n, "Bridge", lang]; after = Lookup[n, "BridgeAfter", None];
      If[StringQ[after] && after =!= prev, br = ""];
      talk = Which[
        MemberQ[{"None", "Part"}, tr], talk,
        br =!= "", br <> " " <> iKGStripSwitch[talk, lang],
        tr === "Shift", iKGHeadIntro[Replace[Lookup[index, First[heads], <||>], Except[_Association] -> <||>], lang] <> iKGStripSwitch[talk, lang],
        True, iKGStripSwitch[talk, lang]];
      If[! TrueQ[Lookup[sl, "Continuation", False]] && ! skipQ,
        terms = Select[iKGList[Lookup[n, "Terms", {}]],
          AssociationQ[#] && StringQ[Lookup[#, "Term", None]] && StringQ[Lookup[#, "Def", None]] &];
        Do[With[{tm = StringTrim[t["Term"]], df = StringTrim[t["Def"]]},
            If[tm =!= "" && df =!= "" && ! KeyExistsQ[explained, ToLowerCase[tm]] && Length[notes] < 2,
              explained[ToLowerCase[tm]] = True;
              AppendTo[notes, tm <> ": " <> df];
              AppendTo[glosses, If[lang === "ja", "\:306a\:304a\:3001" <> tm <> " \:306f\:3001" <> StringTrim[df, "\:3002" | "."] <> "\:3002",
                "Note: " <> tm <> " is " <> StringTrim[df, "."] <> "."]]]],
          {t, terms}]];
      If[glosses =!= {}, talk = StringTrim[talk] <> " " <> StringRiffle[glosses, " "]];
      AppendTo[out, Join[sl, <|"Talk" -> StringTrim[talk], "Transition" -> tr, "Notes" -> notes,
        "Role" -> SourceVaultKGText[n, "Role", lang], "NewHead" -> If[heads === {}, None, First[heads]]|>]];
      If[! TrueQ[Lookup[sl, "Continuation", False]] && ! skipQ && StringQ[x], prev = x]],
    {i, Length[slides]}];
  out];

iKGMdLine[s_String] := StringReplace[StringTrim[s], {"\r\n" -> " ", "\n" -> " "}];

(* \:679a\:306e\:51fa\:3069\:3053\:308d: \:30ce\:30fc\:30c9\:306e\:679a\:306f\:30ce\:30fc\:30c9 Id\:3001\:7528\:8a9e\:30df\:30cb\:8f9e\:66f8\:306f glossary\:3001\:76ee\:6b21\:306f agenda (\:7a7a\:767d\:3084\:62ec\:5f27\:3092\:542b\:3080 Id \:306f\:4ed8\:3051\:306a\:3044) *)
iKGSlideNodeTag[s_Association] := With[{id = If[Lookup[s, "Kind", ""] === "Glossary", "glossary", Lookup[s, "NodeId", None]]},
  If[StringQ[id] && id =!= "" && StringFreeQ[id, WhitespaceCharacter | "{" | "}"], id, None]];

iKGTalkFallback[points_List, title_String, lang_String] := Module[{ps = Select[points, StringQ[#] && # =!= "" &], sep},
  sep = If[lang === "ja", "\:3002", ". "];
  Which[
    ps =!= {}, StringRiffle[StringTrim[#, sep] & /@ ps, sep] <> StringTrim[sep],
    title =!= "", title <> StringTrim[sep],
    True, ""]];

SourceVaultKGOutlineToMarkdown[outline_Association] := Module[{lines = {}, assets = {}, k = 0, title, det},
  title = iKGStr[Lookup[outline, "Title", ""]];
  If[title =!= "", lines = Join[lines, {"---", "Title: " <> title, "---", ""}]];
  Do[
    (* node= \:306f\:679a\:306e\:51fa\:3069\:3053\:308d (\:984c\:76ee\:30bb\:30eb\:306e CellTags "KGNode:<id>")\:3002\:751f\:6210\:3057\:76f4\:3059\:3068\:304d\:306b\:524d\:56de\:306e\:679a\:3092\:898b\:5206\:3051\:3001\:8cea\:7591\:5fdc\:7b54\:3092\:5f15\:304d\:7d99\:3050 *)
    AppendTo[lines, "## " <> iKGMdLine[s["Title"]] <> " {expected=" <> ToString[Round[s["Seconds"]]] <>
      With[{nid = iKGSlideNodeTag[s]}, If[StringQ[nid], " node=" <> nid, ""]] <> "}"];
    If[StringQ[Lookup[s, "Crumb", ""]] && s["Crumb"] =!= "", AppendTo[lines, "crumb: " <> iKGMdLine[s["Crumb"]]]];
    (* \:5c0e\:5165\:6587\:306f\:7b87\:6761\:66f8\:304d\:306e\:524d\:306b\:5730\:306e\:6587\:3067 *)
    If[StringQ[Lookup[s, "Lead", ""]] && s["Lead"] =!= "", AppendTo[lines, iKGMdLine[s["Lead"]]]];
    det = PadRight[Replace[Lookup[s, "Details", {}], Except[_List] -> {}], Length[s["Points"]], ""];
    (* \:56f3\:304c 2 \:679a\:4ee5\:4e0a\:3067\:7b87\:6761 (\:8981\:70b9\:3068\:8a70\:3081\:8fbc\:3093\:3060\:5b50) \:3082 2 \:3064\:4ee5\:4e0a\:306a\:3089\:3001\:7b87\:6761\:306e\:9593\:306b\:56f3\:3092\:631f\:3080
       (\:7b87\:6761 \[RightArrow] \:56f3 \[RightArrow] \:7b87\:6761 \[RightArrow] \:56f3)\:3002\:8868\:306f\:6700\:5f8c *)
    Module[{figs = Select[s["Assets"], ! MemberQ[{"Table", "Image"}, Lookup[#, "Type", ""]] &],
            blocks, nbk, breaks, fi = 0, emitFig, rowQ},
      emitFig[] := (fi++; k++; AppendTo[assets, figs[[fi]]]; AppendTo[lines, "<<FIG" <> ToString[k] <> ">>"]);
      blocks = Join[Table[{"P", i}, {i, Length[s["Points"]]}], Table[{"S", j}, {j, Length[s["Sub"]]}]];
      nbk = Length[blocks];
      (* v1.42: \:6a2a\:4e26\:3073\:306e\:679a\:306f\:7b87\:6761\:3092\:3059\:3079\:3066\:5148\:306b\:51fa\:3057\:3001\:56f3\:306f 1 \:884c\:306b <<FIG1>> <<FIG2>> \:3068\:4e26\:3079\:308b *)
      rowQ = Lookup[s, "FigureLayout", None] === "Row" && Length[figs] >= 2;
      breaks = If[! rowQ && Length[figs] >= 2 && nbk >= 2, Table[Ceiling[i * nbk / Length[figs]], {i, Length[figs] - 1}], {}];
      Do[
        With[{blk = blocks[[b]]},
          If[First[blk] === "P",
            AppendTo[lines, "- " <> iKGMdLine[s["Points"][[Last[blk]]]]];
            If[StringQ[det[[Last[blk]]]] && det[[Last[blk]]] =!= "", AppendTo[lines, "  - " <> iKGMdLine[det[[Last[blk]]]]]],
            With[{sub = s["Sub"][[Last[blk]]]},
              AppendTo[lines, "- " <> iKGMdLine[sub["Label"]]];
              Do[AppendTo[lines, "  - " <> iKGMdLine[p]], {p, sub["Points"]}]]]];
        Do[If[fi < Length[figs], emitFig[]], {Count[breaks, b]}],
        {b, nbk}];
      If[rowQ,
        AppendTo[lines, StringRiffle[Table[(fi++; k++; AppendTo[assets, figs[[fi]]]; "<<FIG" <> ToString[k] <> ">>"), {Length[figs] - fi}], " "]],
        While[fi < Length[figs], emitFig[]]]];
    Do[Switch[Lookup[a, "Type", ""],
        "Table", With[{rows = iKGList[Lookup[a, "Rows", {}]]},
          AppendTo[lines, ""];
          Do[AppendTo[lines, "| " <> StringRiffle[StringReplace[iKGStr /@ iKGList[r], "|" -> "/"], " | "] <> " |"];
            If[ri === 1 && Length[rows] > 1, AppendTo[lines, "| " <> StringRiffle[ConstantArray["---", Length[iKGList[r]]], " | "] <> " |"]],
            {ri, Length[rows]}, {r, {rows[[ri]]}}]],
        "Image", AppendTo[lines, "![](" <> iKGStr[Lookup[a, "Path", ""]] <> ")"],
        _, Null],
      {a, s["Assets"]}];
    If[s["Cite"] =!= "", AppendTo[lines, "cite: " <> iKGMdLine[s["Cite"]]]];
    Do[If[StringQ[nt] && StringTrim[nt] =!= "", AppendTo[lines, "note: " <> iKGMdLine[nt]]], {nt, Replace[Lookup[s, "Notes", {}], Except[_List] -> {}]}];
    If[s["Talk"] =!= "", AppendTo[lines, "talk: " <> iKGMdLine[s["Talk"]]]];
    (* \:60f3\:5b9a\:554f\:7b54 (KG \:306e\:30ce\:30fc\:30c9\:306b\:4fdd\:5b58\:3057\:305f\:3082\:306e\:3002\:8cea\:7591\:5fdc\:7b54\:30bb\:30eb\:306e\:672c\:6587\:3092\:305d\:306e\:307e\:307e) *)
    If[StringQ[Lookup[s, "QA", None]] && StringTrim[s["QA"]] =!= "",
      Do[AppendTo[lines, "qa: " <> q], {q, StringSplit[StringReplace[s["QA"], "\r\n" -> "\n"], "\n"]}]];
    AppendTo[lines, ""],
    {s, Lookup[outline, "Slides", {}]}];
  <|"Markdown" -> StringRiffle[lines, "\n"], "Assets" -> assets, "SlideCount" -> Length[Lookup[outline, "Slides", {}]]|>];

(* ---------------- \:8907\:6570 KG \:306e\:5408\:6210 (\:30b5\:30fc\:30d9\:30a4) ---------------- *)

iKGPrefixId[gid_String, id_String] := If[StringStartsQ[id, "bg:"] || StringContainsQ[id, "/"], id, gid <> "/" <> id];

Options[SourceVaultKGCompose] = {"GraphId" -> Automatic, "Title" -> "", "Language" -> Automatic,
  "Chronological" -> False, "Edges" -> {}, "CrossWeight" -> 0.3};
SourceVaultKGCompose[kgs_List, OptionsPattern[]] := Module[
  {valid = Select[SourceVaultKGValidate /@ kgs, AssociationQ], nodes = <||>, edges = {}, roots = {},
   gid, lang, bgOwners = <||>, rootId = "survey", pairs, cross = {}, res},
  If[valid === {}, Return[Failure["NoGraphs", <|"MessageTemplate" -> "no valid graphs"|>]]];
  gid = Replace[OptionValue["GraphId"], Automatic -> "survey-" <> StringRiffle[Lookup[valid, "GraphId"], "+"]];
  lang = Replace[OptionValue["Language"], Automatic -> First[valid]["Language"]];
  Do[
    Module[{g = valid[[gi]]["GraphId"], kg = valid[[gi]], map},
      (* \:5171\:6709 background \:5c64\:306b\:9023\:7d50\:6e08\:307f\:306e\:5468\:8fba\:77e5\:8b58\:30ce\:30fc\:30c9\:306f bg: \:306e\:5171\:6709 Id \:306b\:4ed8\:3051\:66ff\:3048\:308b (\:8ad6\:6587\:9593\:3067 1 \:3064\:306b\:7d71\:5408\:3055\:308c\:308b) *)
      map = Association[Map[Function[n, n["Id"] ->
        If[n["Layer"] =!= "Paper" && StringQ[n["BackgroundRef"]], n["BackgroundRef"], iKGPrefixId[g, n["Id"]]]], kg["Nodes"]]];
      Do[Module[{id = map[n["Id"]], m = n},
          m["Id"] = id;
          (* \:8ad6\:6587\:3054\:3068\:306b\:51fa\:73fe\:9806\:3092\:305a\:3089\:3057\:3001Source \:6226\:7565\:3067\:8ad6\:6587\:306e\:90e8\:5206\:6728\:304c\:9023\:7d9a\:3059\:308b\:3088\:3046\:306b\:3059\:308b
             (Order \:306e\:7121\:3044\:30ce\:30fc\:30c9\:306f just-in-time \:898f\:5247\:306b\:4efb\:305b\:308b) *)
          m["Order"] = If[NumericQ[n["Order"]], gi * 10000 + n["Order"], None];
          If[StringStartsQ[id, "bg:"],
            If[KeyExistsQ[nodes, id],
              nodes[id]["Importance"] = Max[nodes[id]["Importance"], m["Importance"]];
              nodes[id]["Domains"] = Union[nodes[id]["Domains"], m["Domains"]];
              nodes[id]["Aliases"] = Union[nodes[id]["Aliases"], m["Aliases"]],
              m["Layer"] = "Shared"; nodes[id] = m],
            m["Graph"] = g; nodes[id] = m];
          bgOwners[id] = Append[Lookup[bgOwners, id, {}], g]],
        {n, kg["Nodes"]}];
      (* \:8ad6\:6587\:30ce\:30fc\:30c9\:306e BackgroundRef \:306f bg \:30ce\:30fc\:30c9\:3078\:306e Prerequisite \:3068\:3057\:3066\:8fba\:306b\:843d\:3068\:3059 *)
      Do[If[StringQ[n["BackgroundRef"]] && KeyExistsQ[nodes, n["BackgroundRef"]],
          AppendTo[edges, <|"From" -> n["BackgroundRef"], "To" -> map[n["Id"]], "EdgeKind" -> "Prerequisite", "Weight" -> 0.6|>]],
        {n, kg["Nodes"]}];
      edges = Join[edges, Map[Function[e, Join[e, <|"From" -> map[e["From"]], "To" -> map[e["To"]]|>]], kg["Edges"]]];
      If[StringQ[kg["Root"]], AppendTo[roots, <|"Id" -> map[kg["Root"]], "Graph" -> g,
        "Year" -> With[{y = SourceVaultKGNode[kg, kg["Root"]]["Year"]}, If[IntegerQ[y], y, None]]|>]]],
    {gi, Length[valid]}];
  (* \:5171\:6709 bg \:30ce\:30fc\:30c9\:3078\:306e Contains \:306f\:6700\:521d\:306e\:8ad6\:6587\:306e\:3082\:306e\:3060\:3051\:6b8b\:3059\:3002\:4e21\:65b9\:306e\:7bc0\:304c\:542b\:3080\:3068\:3001\:5f8c\:306e\:8ad6\:6587\:306e\:7bc0\:304c
     \:7f6e\:304b\:308c\:308b\:307e\:3067\:5171\:6709\:30ce\:30fc\:30c9\:304c\:63d0\:793a\:3067\:304d\:305a\:3001\:5148\:306e\:8ad6\:6587\:306e\:4f9d\:5b58\:30ce\:30fc\:30c9\:304c\:5f8c\:306e\:8ad6\:6587\:306e\:533a\:9593\:3078\:62bc\:3057\:51fa\:3055\:308c\:308b *)
  edges = Join[
    Select[edges, ! (#["EdgeKind"] === "Contains" && StringStartsQ[#["To"], "bg:"]) &],
    DeleteDuplicatesBy[Select[edges, #["EdgeKind"] === "Contains" && StringStartsQ[#["To"], "bg:"] &], #["To"] &]];
  (* \:30b5\:30fc\:30d9\:30a4\:6839 *)
  nodes[rootId] = <|"Id" -> rootId, "Kind" -> "Survey", "Label" -> OptionValue["Title"],
    "Summary" -> "", "Points" -> (SourceVaultKGText[nodes[#["Id"]], "Label", lang] & /@ roots),
    "Importance" -> 1., "Difficulty" -> 0.2, "Layer" -> "Paper", "Domains" -> {}, "Order" -> -1|>;
  Do[AppendTo[edges, <|"From" -> rootId, "To" -> r["Id"], "EdgeKind" -> "Contains", "Weight" -> 1.|>], {r, roots}];
  If[TrueQ[OptionValue["Chronological"]],
    With[{sorted = SortBy[Select[roots, IntegerQ[#["Year"]] &], #["Year"] &]},
      Do[AppendTo[edges, <|"From" -> sorted[[i, "Id"]], "To" -> sorted[[i + 1, "Id"]], "EdgeKind" -> "Precedes", "Weight" -> 0.5|>],
        {i, Length[sorted] - 1}]],
    Do[AppendTo[edges, <|"From" -> roots[[i, "Id"]], "To" -> roots[[i + 1, "Id"]], "EdgeKind" -> "Precedes", "Weight" -> 0.4|>],
      {i, Length[roots] - 1}]];
  (* \:5171\:6709 bg \:30ce\:30fc\:30c9\:3092\:4ecb\:3057\:305f\:8ad6\:6587\:9593\:306e\:95a2\:9023 *)
  Do[
    Module[{users = Select[edges, #["From"] === bg && #["EdgeKind"] === "Prerequisite" &]},
      pairs = Subsets[DeleteDuplicates[Lookup[users, "To"]], {2}];
      Do[If[Lookup[nodes[p[[1]]], "Graph", ""] =!= Lookup[nodes[p[[2]]], "Graph", ""],
          AppendTo[cross, <|"From" -> p[[1]], "To" -> p[[2]], "EdgeKind" -> "RelatedTo",
            "Weight" -> OptionValue["CrossWeight"], "EvidenceRefs" -> {bg}|>]], {p, pairs}]],
    {bg, Select[Keys[nodes], StringStartsQ[#, "bg:"] &]}];
  res = SourceVaultKGValidate[<|"GraphId" -> gid, "Title" -> OptionValue["Title"], "Kind" -> "Survey",
    "Language" -> lang, "Sources" -> Flatten[Lookup[valid, "Sources", {}], 1],
    "PrivacyLevel" -> Max[Lookup[valid, "PrivacyLevel", 0.]],
    "Nodes" -> Values[nodes], "Edges" -> Join[edges, cross, Select[iKGAssoc /@ iKGList[OptionValue["Edges"]], AssociationQ]],
    "Root" -> rootId|>];
  If[AssociationQ[res], res["Members"] = Lookup[valid, "GraphId"]];
  res];

(* ---------------- \:5171\:6709 background \:5c64 ---------------- *)

iKGBackgroundFile[bgId_String] := FileNameJoin[{iKGBackgroundDir[],
  StringReplace[bgId, StartOfString ~~ "bg:" -> "bg-"] <> ".json"}];

SourceVaultKGBackgroundList[] := Select[Map[Function[f, With[{d = iKGReadJSON[f]},
    If[AssociationQ[d], KeyMap[ToString, d], Nothing]]],
  Quiet @ Check[FileNames["bg-*.json", iKGBackgroundDir[]], {}]], AssociationQ];

Options[SourceVaultKGBackgroundSearch] = {"Limit" -> 5, "MinScore" -> 0.3};
SourceVaultKGBackgroundSearch[text_String, OptionsPattern[]] := Module[{all = SourceVaultKGBackgroundList[], scored},
  scored = Map[Function[b,
    With[{cands = Join[{iKGStr[Lookup[b, "Label", ""]]}, iKGStrList[Lookup[b, "Aliases", {}]]]},
      <|"Id" -> iKGStr[Lookup[b, "Id", ""]], "Label" -> iKGStr[Lookup[b, "Label", ""]],
        "Score" -> Max[Prepend[iKGBigramSimilarity[text, #] & /@ cands, 0.]],
        "Graphs" -> iKGStrList[Lookup[b, "Graphs", {}]]|>]], all];
  Take[ReverseSortBy[Select[scored, #["Score"] >= OptionValue["MinScore"] &], #["Score"] &], UpTo[OptionValue["Limit"]]]];

Options[SourceVaultKGBackgroundLink] = {"MinScore" -> 0.6};
SourceVaultKGBackgroundLink[kgIn_Association, OptionsPattern[]] := Module[
  {kg = kgIn, linked = {}, created = {}, gid = Lookup[kgIn, "GraphId", ""], nodes},
  nodes = Map[Function[n,
    If[n["Layer"] =!= "Background" && n["Kind"] =!= "Background", n,
      Module[{label = iKGTextValue[n["Label"], "ja", n["PrimaryLanguage"]], hits, bgId, file, rec},
        hits = If[StringQ[n["BackgroundRef"]] && FileExistsQ[iKGBackgroundFile[n["BackgroundRef"]]],
          {<|"Id" -> n["BackgroundRef"], "Score" -> 1.|>},
          SourceVaultKGBackgroundSearch[label, "Limit" -> 1, "MinScore" -> OptionValue["MinScore"]]];
        If[hits =!= {},
          bgId = hits[[1, "Id"]]; file = iKGBackgroundFile[bgId];
          rec = iKGReadJSON[file];
          If[AssociationQ[rec],
            rec = KeyMap[ToString, rec];
            rec["Graphs"] = Union[iKGStrList[Lookup[rec, "Graphs", {}]], {gid}];
            rec["Aliases"] = Union[iKGStrList[Lookup[rec, "Aliases", {}]], {label}, iKGStrList[n["Aliases"]]];
            iKGWriteJSON[file, rec]];
          AppendTo[linked, {n["Id"], bgId}];
          Append[n, "BackgroundRef" -> bgId],
          bgId = "bg:" <> iKGSlug[label];
          rec = Join[KeyDrop[n, {"BackgroundRef", "Source", "Order"}],
            <|"Id" -> bgId, "Layer" -> "Shared", "Graphs" -> {gid}, "CreatedAtUTC" -> iKGUTCNow[]|>];
          iKGWriteJSON[iKGBackgroundFile[bgId], rec];
          AppendTo[created, {n["Id"], bgId}];
          Append[n, "BackgroundRef" -> bgId]]]]],
    Lookup[kg, "Nodes", {}]];
  kg["Nodes"] = nodes;
  <|"Graph" -> kg, "Linked" -> linked, "Created" -> created|>];

(* \:904e\:53bb\:30c7\:30c3\:30ad\:306e\:518d\:5229\:7528\:5019\:88dc (SourceVault_kb \:304c\:30ed\:30fc\:30c9\:6e08\:307f\:306e\:3068\:304d\:3060\:3051) *)
Options[SourceVaultKGSuggestPastSlides] = {"Limit" -> 2, "MinScore" -> 1.5};
SourceVaultKGSuggestPastSlides[kg_Association, kbId_String, OptionsPattern[]] := Module[{srcs, pathOf, out = {}},
  If[Length[DownValues[SourceVault`SourceVaultKBSearch]] === 0 ||
     ! TrueQ[Quiet @ Check[SourceVault`SourceVaultKBLoadedQ[kbId], False]], Return[{}]];
  srcs = Quiet @ Check[SourceVault`SourceVaultKBSources[kbId], {}];
  pathOf = Association[Map[(iKGStr[Lookup[#, "SourceId", ""]] -> iKGStr[Lookup[#, "Path", ""]]) &, Select[srcs, AssociationQ]]];
  Do[
    Module[{label = iKGTextValue[n["Label"], "ja", n["PrimaryLanguage"]], hits},
      hits = Quiet @ Check[SourceVault`SourceVaultKBSearch[kbId, label, "Limit" -> OptionValue["Limit"]], {}];
      hits = Select[iKGList[hits], AssociationQ[#] && iKGNum[Lookup[#, "Score", 0.], 0.] >= OptionValue["MinScore"] &];
      Do[AppendTo[out, <|"NodeId" -> n["Id"], "Label" -> label,
          "Deck" -> Lookup[pathOf, iKGStr[Lookup[h, "SourceId", ""]], ""],
          "Slide" -> Lookup[h, "SlideIndex", None], "Title" -> iKGStr[Lookup[h, "Title", ""]],
          "Score" -> iKGNum[Lookup[h, "Score", 0.], 0.]|>], {h, hits}]],
    {n, Select[Lookup[kg, "Nodes", {}], #["Layer"] =!= "Paper" &]}];
  out];

(* ---------------- \:30d7\:30ed\:30f3\:30d7\:30c8 (\:7d14\:95a2\:6570) ---------------- *)

iKGEdgeKindDoc[] := StringRiffle[Map[Function[k,
  "  - " <> k <> ": " <> Switch[k,
    "Prerequisite", "From \:306f To \:3092\:7406\:89e3\:3059\:308b\:305f\:3081\:306e\:524d\:63d0 (From \:3092\:5148\:306b\:8aac\:660e\:3059\:308b\:3002\:96e3\:6613\:5ea6\:9806\:5e8f)",
    "Precedes", "From \:306f To \:3088\:308a\:5148\:306b\:8d77\:304d\:305f / \:5148\:306b\:884c\:308f\:308c\:305f (\:5e74\:4ee3\:30fb\:5b9f\:9a13\:306e\:9806\:5e8f)",
    "Derives", "To \:306f From \:304b\:3089\:5c0e\:304b\:308c\:308b (\:5c0e\:51fa\:9806\:5e8f)",
    "Motivates", "From (\:554f\:3044\:30fb\:8ab2\:984c) \:304c To (\:624b\:6cd5\:30fb\:5b9f\:9a13) \:3092\:52d5\:6a5f\:3065\:3051\:308b",
    "LeadsTo", "From (\:7d50\:679c) \:304c To (\:7d50\:8ad6\:30fb\:542b\:610f) \:306b\:3064\:306a\:304c\:308b (\:56e0\:679c)",
    "Contains", "From (\:7bc0\:30fb\:307e\:3068\:307e\:308a) \:304c To \:3092\:542b\:3080 (\:968e\:5c64)",
    "Supports", "From (\:8a3c\:62e0\:30fb\:56f3\:30fb\:30c7\:30fc\:30bf) \:304c To (\:4e3b\:5f35) \:3092\:652f\:3048\:308b (\:9806\:5e8f\:5236\:7d04\:306a\:3057)",
    "Explains", "From \:304c To \:3092\:89e3\:8aac\:3059\:308b (\:9806\:5e8f\:5236\:7d04\:306a\:3057)",
    "Contrasts", "From \:3068 To \:306f\:5bfe\:6bd4\:3055\:308c\:308b (\:9806\:5e8f\:5236\:7d04\:306a\:3057)",
    "RelatedTo", "\:95a2\:9023\:304c\:3042\:308b (\:9806\:5e8f\:5236\:7d04\:306a\:3057)",
    "Cites", "From \:304c To \:3092\:5f15\:7528\:3059\:308b (\:9806\:5e8f\:5236\:7d04\:306a\:3057)",
    _, ""]], Keys[SourceVault`$SourceVaultKGEdgeKinds]], "\n"];

iKGSchemaDoc[] := "{\n  \"GraphId\": \"<id>\", \"Title\": \"<\:8ad6\:6587\:984c\:76ee>\", \"Language\": \"ja\", \"Kind\": \"Paper\",\n" <>
  "  \"Root\": \"<\:4e3b\:5f35\:30ce\:30fc\:30c9\:306e Id>\",\n" <>
  "  \"Nodes\": [{\"Id\": \"claim\", \"Kind\": \"Claim|Concept|Definition|Method|Experiment|Result|Equation|Figure|Question|Conclusion|Background|Section\",\n" <>
  "    \"Label\": \"\:77ed\:3044\:540d\:8a5e\:53e5 (\:30b9\:30e9\:30a4\:30c9\:30bf\:30a4\:30c8\:30eb\:306b\:306a\:308b)\", \"Summary\": \"1-2 \:6587\:306e\:8981\:7d04 (talk \:306e\:9aa8\:5b50)\",\n" <>
  "    \"Points\": [\"\:4f53\:8a00\:6b62\:3081\:306e\:7b87\:6761\:66f8\:304d 2-5 \:884c\"], \"Difficulty\": 0.0-1.0, \"Importance\": 0.0-1.0,\n" <>
  "    \"Domains\": [\"\:96fb\:6c17\:5316\:5b66\", \"\:9ad8\:5206\:5b50\"], \"Year\": 2024 (\:80cc\:666f\:4e8b\:5b9f\:306e\:5e74\:4ee3\:3002\:7121\:3051\:308c\:3070\:7701\:7565), \"Order\": \:51fa\:73fe\:9806\:306e\:6574\:6570,\n" <>
  "    \"Layer\": \"Paper|Background\", \"Cite\": \"(\:8457\:8005 \:5e74) Fig. n\",\n" <>
  "    \"Assets\": [{\"Type\": \"NotebookFigure\", \"Ref\": \"<key>\", \"N\": 3}, {\"Type\": \"Formula\", \"Ref\": \"<key>\", \"N\": 1},\n" <>
  "               {\"Type\": \"PDFFigure\", \"Ref\": \"<pdfkey>\", \"Page\": 4, \"Crop\": [[0.1,0.9],[0.2,0.6]]}, {\"Type\": \"Table\", \"Rows\": [[\"\:9805\:76ee\",\"\:5024\"],[\"a\",\"1\"]]}]}],\n" <>
  "  \"Edges\": [{\"From\": \"q1\", \"To\": \"method\", \"EdgeKind\": \"Motivates\", \"Weight\": 0.0-1.0, \"Confidence\": 0.0-1.0, \"EvidenceRefs\": [\"[FIG2]\"]}]\n}";

Options[SourceVaultKGExtractionPrompt] = {"GraphId" -> "paper", "Title" -> "", "Language" -> "ja",
  "SourceKey" -> "", "PDFKey" -> "", "MaxNodes" -> 60, "MinNodes" -> 25};
SourceVaultKGExtractionPrompt[sourceText_String, OptionsPattern[]] :=
  "\:3042\:306a\:305f\:306f\:8ad6\:6587\:306e\:5185\:5bb9\:3092\:300c\:767a\:8868\:7528\:306e\:77e5\:8b58\:30b0\:30e9\:30d5\:300d\:306b\:69cb\:9020\:5316\:3059\:308b\:5c02\:9580\:5bb6\:3067\:3059\:3002\:4ee5\:4e0b\:306e\:672c\:6587\:304b\:3089\:3001\:30b9\:30e9\:30a4\:30c9\:3084\:89e3\:8aac\:3092\:52d5\:7684\:306b\:751f\:6210\:3059\:308b\:305f\:3081\:306e\:77e5\:8b58\:30b0\:30e9\:30d5\:3092 JSON \:3060\:3051\:3067\:51fa\:529b\:3057\:3066\:304f\:3060\:3055\:3044\:3002\n\n" <>
  "\:5bfe\:8c61: " <> If[OptionValue["Title"] =!= "", OptionValue["Title"], "(\:984c\:76ee\:306f\:672c\:6587\:304b\:3089\:53d6\:308b)"] <>
  "  GraphId: " <> OptionValue["GraphId"] <> "  \:8a00\:8a9e: " <> OptionValue["Language"] <> "\n" <>
  If[OptionValue["SourceKey"] =!= "", "\:672c\:6587\:30ce\:30fc\:30c8\:30d6\:30c3\:30af\:306e key: " <> OptionValue["SourceKey"] <> " (Assets \:306e NotebookFigure / Formula \:306e Ref \:306b\:4f7f\:3046\:3002[FIGn] / [EQn] \:306f\:672c\:6587\:4e2d\:306e\:756a\:53f7)\n", ""] <>
  If[OptionValue["PDFKey"] =!= "", "\:539f\:8ad6\:6587 PDF \:306e key: " <> OptionValue["PDFKey"] <> " (Assets \:306e PDFFigure \:306e Ref \:306b\:4f7f\:3046)\n", ""] <>
  "\n\:51fa\:529b JSON \:306e\:30b9\:30ad\:30fc\:30de:\n" <> iKGSchemaDoc[] <> "\n\n" <>
  "\:8fba (Edges) \:306e\:7a2e\:5225\:3002\:9806\:5e8f\:5236\:7d04\:306e\:3042\:308b\:7a2e\:5225\:306f\:3059\:3079\:3066\:300cFrom \:3092 To \:3088\:308a\:5148\:306b\:63d0\:793a\:3059\:308b\:300d\:5411\:304d\:3067\:66f8\:304f:\n" <> iKGEdgeKindDoc[] <> "\n\n" <>
  "\:4f5c\:308a\:65b9\:306e\:898f\:5247:\n" <>
  "1. \:30ce\:30fc\:30c9\:306f " <> ToString[OptionValue["MinNodes"]] <> "\:301c" <> ToString[OptionValue["MaxNodes"]] <> " \:500b\:30021 \:30ce\:30fc\:30c9 = 1 \:679a\:306e\:30b9\:30e9\:30a4\:30c9\:306b\:306a\:308a\:3046\:308b\:7c92\:5ea6 (1 \:3064\:306e\:554f\:3044\:30fb\:624b\:6cd5\:30fb\:5b9f\:9a13\:30fb\:7d50\:679c\:30fb\:5f0f\:30fb\:56f3\:30fb\:6982\:5ff5)\:3002Root \:306f\:8ad6\:6587\:306e\:4e3b\:5f35 (Claim) 1 \:3064\:3002\n" <>
  "2. \:8ad6\:6587\:306e\:7bc0 (\:80cc\:666f / \:624b\:6cd5 / \:7d50\:679c / \:8b70\:8ad6 / \:7d50\:8ad6) \:306f Kind=Section \:306e\:30ce\:30fc\:30c9\:306b\:3057\:3066 Contains \:8fba\:3067\:4e0b\:4f4d\:30ce\:30fc\:30c9\:3092\:307e\:3068\:3081\:308b\:3002Order \:306f\:672c\:6587\:306e\:51fa\:73fe\:9806\:3002\n" <>
  "3. \:8ad6\:6587\:672c\:6587\:306b\:7121\:3044\:304c\:7406\:89e3\:306b\:5fc5\:8981\:306a\:524d\:63d0\:77e5\:8b58 (\:5b9a\:7fa9\:30fb\:53e4\:5178\:7684\:306a\:5f0f\:30fb\:5148\:884c\:7814\:7a76\:306e\:4e8b\:5b9f) \:306f Layer=Background \:306e\:30ce\:30fc\:30c9\:3068\:3057\:3066\:8ffd\:52a0\:3057\:3001\:305d\:308c\:3092\:524d\:63d0\:3068\:3059\:308b\:8ad6\:6587\:30ce\:30fc\:30c9\:3078 Prerequisite \:8fba\:3092\:5f35\:308b\:3002Domains (\:9818\:57df\:540d) \:3068 Difficulty (\:305d\:306e\:9818\:57df\:306e\:5b66\:90e8\:30ec\:30d9\:30eb\:3092 0.5 \:3068\:3059\:308b) \:3092\:5fc5\:305a\:4ed8\:3051\:308b\:3002\n" <>
  "4. \:5b9f\:9a13\:30fb\:5b9a\:7406\:30fb\:5148\:884c\:7814\:7a76\:306e\:5e74\:4ee3\:9806\:306f Precedes\:3001\:5f0f\:3084\:91cf\:306e\:5c0e\:51fa\:9806\:306f Derives\:3001\:554f\:3044\[RightArrow]\:624b\:6cd5\:306f Motivates\:3001\:7d50\:679c\[RightArrow]\:7d50\:8ad6\:306f LeadsTo\:3001\:56f3\:3084\:30c7\:30fc\:30bf\[RightArrow]\:4e3b\:5f35\:306f Supports \:3067\:8868\:3059\:3002\:96e3\:3057\:3044\:6982\:5ff5\:306e\:524d\:306b\:6613\:3057\:3044\:6982\:5ff5\:304c\:6765\:308b\:3088\:3046 Prerequisite \:3092\:5f35\:308b (\:4f8b: Lagrangian \:306e\:5f8c\:306b F=ma \:306e\:8aac\:660e\:304c\:6765\:3066\:306f\:3044\:3051\:306a\:3044)\:3002\n" <>
  "5. Importance \:306f\:300c\:305d\:306e\:8ad6\:6587\:306e\:4e3b\:5f35\:3092\:4f1d\:3048\:308b\:306e\:306b\:6b20\:304b\:305b\:306a\:3044\:5ea6\:5408\:3044\:300d\:3002Difficulty \:306f\:8074\:304d\:624b\:306e\:524d\:63d0\:77e5\:8b58\:306a\:3057\:3067\:7406\:89e3\:3059\:308b\:306e\:306b\:8981\:3059\:308b\:6c34\:6e96 (0=\:5e38\:8b58, 0.3=\:9ad8\:6821, 0.5=\:5b66\:90e8, 0.7=\:5927\:5b66\:9662, 0.9=\:5c02\:9580\:5bb6)\:3002\n" <>
  "6. \:56f3\:30fb\:5f0f\:30fb\:5199\:771f\:306f\:672c\:6587\:306e [FIGn] / [EQn] \:3092 Assets \:3067\:53c2\:7167\:3057\:3001Cite \:306b\:51fa\:5178\:3092\:66f8\:304f\:3002\:5f0f\:306f\:6587\:5b57\:5217\:3067\:66f8\:304d\:76f4\:3055\:306a\:3044 (Formula \:8cc7\:7523\:3067\:539f\:5f0f\:3092\:5f15\:7528\:3059\:308b)\:3002\n" <>
  "7. Points \:306f\:4f53\:8a00\:6b62\:3081\:3067\:77ed\:304f\:3001Summary \:306f \:3067\:3059\:30fb\:307e\:3059\:8abf 1-2 \:6587\:3002\:3059\:3079\:3066 " <> OptionValue["Language"] <> " \:3067\:66f8\:304f\:3002\n" <>
  "8. \:51fa\:529b\:306f JSON \:30aa\:30d6\:30b8\:30a7\:30af\:30c8\:306e\:307f (\:524d\:7f6e\:304d\:30fb\:8aac\:660e\:30fb\:30b3\:30fc\:30c9\:30d5\:30a7\:30f3\:30b9\:4ee5\:5916\:306e\:6587\:7ae0\:3092\:4ed8\:3051\:306a\:3044)\:3002\n\n" <>
  "=== \:672c\:6587 ===\n" <> sourceText <> "\n=== \:672c\:6587\:3053\:3053\:307e\:3067 ===";

Options[SourceVaultKGBackgroundPrompt] = {"MaxNodes" -> 12};
SourceVaultKGBackgroundPrompt[kg_Association, audSpec_, OptionsPattern[]] := Module[
  {aud = SourceVaultKGAudience[audSpec], lang = Lookup[kg, "Language", "ja"], listing},
  listing = StringRiffle[Map[Function[n,
    "- " <> n["Id"] <> " [" <> n["Kind"] <> ", D=" <> ToString[n["Difficulty"]] <> ", " <> StringRiffle[n["Domains"], "/"] <> "] " <>
      SourceVaultKGText[n, "Label", lang]], Lookup[kg, "Nodes", {}]], "\n"];
  "\:4ee5\:4e0b\:306f\:8ad6\:6587\:300c" <> Lookup[kg, "Title", ""] <> "\:300d\:306e\:77e5\:8b58\:30b0\:30e9\:30d5\:306e\:30ce\:30fc\:30c9\:4e00\:89a7\:3067\:3059\:3002\:8074\:304d\:624b\:306f\:6b21\:306e\:901a\:308a:\n" <>
  "  \:4e3b\:984c\:306e\:7406\:89e3\:5ea6: " <> ToString[aud["Level"]] <> "  \:524d\:63d0\:306b\:3067\:304d\:308b\:9818\:57df\:3068\:7406\:89e3\:5ea6: " <>
    StringRiffle[KeyValueMap[#1 <> "=" <> ToString[#2] &, aud["Knowledge"]], ", "] <>
  If[aud["Description"] =!= "", "  \:88dc\:8db3: " <> aud["Description"], ""] <> "\n\n" <>
  listing <> "\n\n" <>
  "\:3053\:306e\:8074\:304d\:624b\:304c\:30ce\:30fc\:30c9\:3092\:7406\:89e3\:3059\:308b\:306e\:306b\:8db3\:308a\:306a\:3044\:524d\:63d0\:77e5\:8b58 (\:5b9a\:7fa9\:30fb\:57fa\:790e\:6982\:5ff5\:30fb\:53e4\:5178\:7684\:306a\:7d50\:679c\:30fb\:7528\:8a9e) \:3092\:3001\:6700\:5927 " <> ToString[OptionValue["MaxNodes"]] <>
  " \:500b\:306e Layer=Background \:30ce\:30fc\:30c9\:3068\:3057\:3066\:8ffd\:52a0\:3057\:3001\:5404\:30ce\:30fc\:30c9\:304b\:3089\:3001\:305d\:308c\:3092\:524d\:63d0\:3068\:3059\:308b\:65e2\:5b58\:30ce\:30fc\:30c9\:3078 Prerequisite \:8fba (From=\:65b0\:30ce\:30fc\:30c9, To=\:65e2\:5b58\:30ce\:30fc\:30c9) \:3092\:5f35\:3063\:3066\:304f\:3060\:3055\:3044\:3002" <>
  "\:8074\:304d\:624b\:304c\:65e2\:306b\:77e5\:3063\:3066\:3044\:308b\:9818\:57df (\:7406\:89e3\:5ea6\:304c Difficulty \:4ee5\:4e0a) \:306e\:3082\:306e\:306f\:8ffd\:52a0\:3057\:306a\:3044\:3067\:304f\:3060\:3055\:3044\:3002\:5404\:30ce\:30fc\:30c9\:306b\:306f Label / Summary (1-2 \:6587) / Points (2-4 \:884c) / Difficulty / Domains / Year (\:53e4\:5178\:7684\:7d50\:679c\:306a\:3089) \:3092\:4ed8\:3051\:307e\:3059\:3002\n" <>
  "\:51fa\:529b\:306f\:5dee\:5206 JSON {\"Nodes\": [...], \"Edges\": [...]} \:306e\:307f\:3002\:3059\:3079\:3066 " <> lang <> " \:3067\:66f8\:304f\:3002"];

Options[SourceVaultKGSummaryPrompt] = {"Language" -> Automatic};
SourceVaultKGSummaryPrompt[kg_Association, tree_Association, OptionsPattern[]] := Module[
  {lang = Replace[OptionValue["Language"], Automatic -> Lookup[kg, "Language", "ja"]], index = iKGNodeIndex[kg], lines},
  lines = Map[Function[id, StringRepeat["  ", tree["Depth"][id]] <> "- " <> id <> ": " <>
    SourceVaultKGText[index[id], "Label", lang]], tree["Order"]];
  "\:4ee5\:4e0b\:306f\:767a\:8868\:306e\:9806\:5e8f\:6728 (\:5b57\:4e0b\:3052\:304c\:968e\:5c64\:3001\:4e0a\:304b\:3089\:9806\:306b\:8a71\:3059) \:3067\:3059\:3002\n" <> StringRiffle[lines, "\n"] <> "\n\n" <>
  "\:5404\:5185\:90e8\:30ce\:30fc\:30c9 (\:5b50\:3092\:6301\:3064\:30ce\:30fc\:30c9) \:306b\:3064\:3044\:3066\:3001\:305d\:306e\:90e8\:5206\:6728\:5168\:4f53\:3092 1-2 \:6587\:3067\:8981\:7d04\:3057\:305f Summary \:3092\:66f8\:3044\:3066\:304f\:3060\:3055\:3044\:3002" <>
  "\:307e\:305f\:3001\:3053\:306e\:9806\:5e8f\:3067\:8aac\:660e\:3057\:305f\:3068\:304d\:7834\:7dbb\:3059\:308b\:7b87\:6240 (\:524d\:63d0\:304c\:5f8c\:306b\:51fa\:308b / \:98db\:8e8d / \:91cd\:8907 / \:629c\:3051) \:304c\:3042\:308c\:3070 Issues \:306b\:5217\:6319\:3057\:3066\:304f\:3060\:3055\:3044\:3002\n" <>
  "\:51fa\:529b\:306f JSON {\"Nodes\": [{\"Id\": \"...\", \"Summary\": \"...\"}], \"Issues\": [{\"NodeId\": \"...\", \"Issue\": \"...\", \"Fix\": \"...\"}]} \:306e\:307f\:3002\:8a00\:8a9e\:306f " <> lang <> "\:3002"];

Options[SourceVaultKGTalkPrompt] = {"Style" -> "\:3067\:3059\:30fb\:307e\:3059\:8abf\:30011 \:679a 2-6 \:6587"};
(* v1.48: \:7b87\:6761\:66f8\:304d\:306e\:8aad\:307f\:4e0a\:3052\:306b\:3057\:306a\:3044\:3002\:5404\:679a\:306e\:5f79\:5272 (role) \:3068\:524d\:5f8c\:306e\:3064\:306a\:304c\:308a (transition) \:3092\:6e21\:3057\:3001\:610f\:5473\:30fb\:7406\:7531\:3092\:88dc\:3063\:3066\:8a71\:3055\:305b\:308b *)
SourceVaultKGTalkPrompt[outline_Association, OptionsPattern[]] := Module[{lines, trName},
  trName[t_] := Switch[t,
    "Continue", "\:7d9a\:304d (\:524d\:306e\:679a\:3068\:540c\:3058\:89aa\:3002\:8a71\:984c\:8ee2\:63db\:306e\:8a9e\:306f\:4f7f\:308f\:306a\:3044)",
    "Shift", "\:8a71\:984c\:8ee2\:63db (\:65b0\:3057\:3044\:898b\:51fa\:3057\:306b\:5165\:308b)",
    "Return", "\:8a71\:984c\:8ee2\:63db (\:4e00\:3064\:4e0a\:306e\:6bb5\:306e\:6b21\:306e\:8a71\:3078)",
    "Part", "\:90e8\:306e\:5165\:53e3",
    _, "-"];
  lines = MapIndexed[Function[{s, i},
    ToString[First[i]] <> ". " <> s["Title"] <> "\n   transition: " <> trName[Lookup[s, "Transition", None]] <>
      With[{r = Lookup[s, "Role", ""]}, If[StringQ[r] && r =!= "", "\n   role: " <> r, ""]] <>
      "\n   points: " <> StringRiffle[s["Points"], " / "] <>
      If[s["Sub"] =!= {}, "\n   sub: " <> StringRiffle[Lookup[s["Sub"], "Label"], " / "], ""] <>
      "\n   talk(draft): " <> s["Talk"]], Lookup[outline, "Slides", {}]];
  "\:4ee5\:4e0b\:306f\:30b9\:30e9\:30a4\:30c9\:306e\:69cb\:6210 (\:9806\:5e8f\:30fb\:30bf\:30a4\:30c8\:30eb\:30fb\:7b87\:6761\:66f8\:304d\:306f\:78ba\:5b9a\:3002\:5909\:66f4\:3057\:306a\:3044) \:3068 talk \:306e\:4e0b\:66f8\:304d\:3067\:3059\:3002\n" <> StringRiffle[lines, "\n"] <> "\n\n" <>
  "\:5404\:679a\:306e talk \:3092\:767a\:8868\:539f\:7a3f\:3068\:3057\:3066\:78e8\:3044\:3066\:304f\:3060\:3055\:3044 (" <> OptionValue["Style"] <> ")\:3002\:30b9\:30e9\:30a4\:30c9\:306b\:7121\:3044\:4e8b\:5b9f\:30fb\:6570\:5024\:3092\:4f5c\:3089\:306a\:3044\:3002" <>
  "\:7b87\:6761\:66f8\:304d\:306f\:753b\:9762\:3067\:898b\:3048\:308b\:306e\:3067\:8aad\:307f\:4e0a\:3052\:306a\:3044\:3002\:305d\:306e\:679a\:306e\:5f79\:5272 (role: \:306a\:305c\:3053\:306e\:679a\:304c\:3053\:3053\:306b\:3042\:308a\:3001\:8a71\:5168\:4f53\:306e\:4e2d\:3067\:4f55\:3092\:6e96\:5099\:3057\:4f55\:3092\:793a\:3059\:304b) \:304c\:8074\:304d\:624b\:306b\:4f1d\:308f\:308b\:3088\:3046\:3001" <>
  "\:610f\:5473\:30fb\:7406\:7531\:30fb\:524d\:5f8c\:3068\:306e\:3064\:306a\:304c\:308a\:3092\:88dc\:3063\:3066\:8a71\:3059\:3002transition \:304c\:300c\:7d9a\:304d\:300d\:306e\:679a\:306f\:524d\:306e\:679a\:306e\:7d9a\:304d\:3068\:3057\:3066\:8a71\:3057\:3001\:300c\:3053\:3053\:3067\:306f\:300d\:300c\:3055\:3066\:300d\:306a\:3069\:306e\:8a71\:984c\:8ee2\:63db\:306e\:8a9e\:3067\:59cb\:3081\:306a\:3044\:3002" <>
  "\:300c\:8a71\:984c\:8ee2\:63db\:300d\:306e\:679a\:3060\:3051\:3001\:4f55\:306b\:79fb\:308b\:304b\:3068\:306a\:305c\:4eca\:305d\:308c\:3092\:6271\:3046\:304b\:3092\:4e00\:8a00\:3067\:544a\:3052\:308b\:3002\:90e8\:306e\:5165\:53e3\:306e\:6a4b\:6e21\:3057\:306e\:4e00\:6587\:3068\:3001\:4e0b\:66f8\:304d\:306e\:7528\:8a9e\:306e\:4e00\:884c\:8aac\:660e (\:300c\:306a\:304a\:3001\:301c\:306f\:3001\:2026\:300d) \:306f\:6b8b\:3059\:3002" <>
  "\:51fa\:529b\:306f JSON {\"Talks\": [{\"Slide\": 1, \"Talk\": \"...\"}]} \:306e\:307f\:3002\:8a00\:8a9e\:306f " <> Lookup[outline, "Language", "ja"] <> "\:3002"];

Options[SourceVaultKGTranslatePrompt] = {};
SourceVaultKGTranslatePrompt[kg_Association, lang_String, OptionsPattern[]] := Module[
  {primary = Lookup[kg, "Language", "ja"], items},
  items = Map[Function[n, <|"Id" -> n["Id"], "Label" -> SourceVaultKGText[n, "Label", primary],
    "Summary" -> SourceVaultKGText[n, "Summary", primary], "Points" -> SourceVaultKGText[n, "Points", primary],
    "Talk" -> SourceVaultKGText[n, "Talk", primary]|>], Lookup[kg, "Nodes", {}]];
  "\:4ee5\:4e0b\:306e\:77e5\:8b58\:30b0\:30e9\:30d5\:306e\:30ce\:30fc\:30c9\:306e\:30c6\:30ad\:30b9\:30c8 (Label / Summary / Points / Talk) \:3092 " <> lang <> " \:306b\:7ffb\:8a33\:3057\:3066\:304f\:3060\:3055\:3044\:3002" <>
  "Id \:306f\:305d\:306e\:307e\:307e\:3001\:69cb\:9020\:3082\:5909\:3048\:305a\:3001\:5c02\:9580\:7528\:8a9e\:306f\:5206\:91ce\:306e\:6a19\:6e96\:8a33\:3092\:4f7f\:3044\:307e\:3059\:3002\:7a7a\:306e\:9805\:76ee\:306f\:7a7a\:306e\:307e\:307e\:3002\n" <>
  "\:51fa\:529b\:306f JSON {\"Nodes\": [{\"Id\": \"...\", \"Label\": \"...\", \"Summary\": \"...\", \"Points\": [...], \"Talk\": \"...\"}]} \:306e\:307f\:3002\n\n" <>
  iKGJSONString[<|"Nodes" -> items|>]];

(* ---------------- Graph \:6295\:5f71\:3068 View ---------------- *)

$kgKindColors = <|"Claim" -> RGBColor[0.88, 0.49, 0.08], "Conclusion" -> RGBColor[0.88, 0.49, 0.08],
  "Survey" -> RGBColor[0.88, 0.49, 0.08], "Section" -> RGBColor[0.55, 0.55, 0.55],
  "Background" -> RGBColor[0.35, 0.6, 0.6], "Equation" -> RGBColor[0.45, 0.42, 0.7],
  "Figure" -> RGBColor[0.45, 0.42, 0.7], "Result" -> RGBColor[0.62, 0.11, 0.11],
  "Experiment" -> RGBColor[0.62, 0.11, 0.11], "Method" -> RGBColor[0.3, 0.55, 0.5]|>;

Options[SourceVaultKGGraph] = {"Order" -> False, "Labels" -> True, "Language" -> Automatic};
SourceVaultKGGraph[kg_Association, OptionsPattern[]] := Module[
  {lang = Replace[OptionValue["Language"], Automatic -> Lookup[kg, "Language", "ja"]], nodes = Lookup[kg, "Nodes", {}],
   edges = Lookup[kg, "Edges", {}], es, styles},
  If[TrueQ[OptionValue["Order"]], edges = Select[edges, TrueQ[#["Order"]] &]];
  es = If[TrueQ[#["Order"]], DirectedEdge[#["From"], #["To"]], UndirectedEdge[#["From"], #["To"]]] & /@ edges;
  styles = MapThread[Function[{e, ed}, e -> If[TrueQ[ed["Order"]], Directive[Thick, GrayLevel[0.25]], Directive[Dashed, GrayLevel[0.65]]]], {es, edges}];
  Graph[Lookup[nodes, "Id", {}], es,
    VertexLabels -> If[TrueQ[OptionValue["Labels"]],
      Map[(#["Id"] -> Placed[SourceVaultKGText[#, "Label", lang], Tooltip]) &, nodes], None],
    VertexStyle -> Map[(#["Id"] -> Lookup[$kgKindColors, #["Kind"], RGBColor[0.62, 0.11, 0.11]]) &, nodes],
    VertexSize -> Map[(#["Id"] -> 0.2 + 0.6 * #["Importance"]) &, nodes],
    EdgeStyle -> styles, GraphLayout -> "LayeredDigraphEmbedding"]];

SourceVaultKGToTopicItemGraph[kg_Association] := Module[
  {lang = Lookup[kg, "Language", "ja"], nodes = Lookup[kg, "Nodes", {}], edges = Lookup[kg, "Edges", {}]},
  <|"ObjectClass" -> "SourceVaultTopicItemGraph", "GraphId" -> "svtopicgraph:" <> Lookup[kg, "GraphId", ""],
    "Nodes" -> Map[<|"TopicItemRef" -> #["Id"], "Label" -> SourceVaultKGText[#, "Label", lang], "SupportParagraphs" -> {}|> &, nodes],
    "Edges" -> Map[<|"From" -> #["From"], "To" -> #["To"], "EdgeKind" -> #["EdgeKind"], "Weight" -> #["Weight"],
      "EvidenceRefs" -> #["EvidenceRefs"]|> &, edges],
    "MailSessionRefs" -> {}, "NodeCount" -> Length[nodes], "EdgeCount" -> Length[edges],
    "EdgeKindTally" -> Counts[Lookup[edges, "EdgeKind", {}]]|>];

iKGViewRows[rows_List] := Take[rows, UpTo[SourceVault`$SourceVaultKGViewMaxRows]];

SourceVaultKGView[kg_Association] := Module[{lang = Lookup[kg, "Language", "ja"]},
  Dataset[iKGViewRows[Map[Function[n,
    <|"Id" -> n["Id"], "Kind" -> n["Kind"], "Label" -> SourceVaultKGText[n, "Label", lang],
      "Layer" -> n["Layer"], "Difficulty" -> n["Difficulty"], "Importance" -> n["Importance"],
      "Domains" -> StringRiffle[n["Domains"], ", "], "Assets" -> Length[n["Assets"]],
      "Background" -> Replace[n["BackgroundRef"], None -> ""]|>], Lookup[kg, "Nodes", {}]]]]];

SourceVaultKGTreeView[kg_Association, tree_Association] := Module[{index = iKGNodeIndex[kg], lang = Lookup[kg, "Language", "ja"]},
  Dataset[iKGViewRows[Map[Function[id,
    <|"Label" -> StringRepeat["\[LongDash] ", tree["Depth"][id]] <> SourceVaultKGText[index[id], "Label", lang],
      "Depth" -> tree["Depth"][id], "Id" -> id, "Kind" -> index[id]["Kind"],
      "Importance" -> index[id]["Importance"]|>], tree["Order"]]]]];

SourceVaultKGPlanView[kg_Association, plan_Association] := Module[{index = iKGNodeIndex[kg], lang = Lookup[kg, "Language", "ja"]},
  Dataset[iKGViewRows[MapIndexed[Function[{s, i},
    <|"No" -> First[i], "Title" -> StringRepeat["\[LongDash] ", s["Depth"]] <> SourceVaultKGText[index[s["NodeId"]], "Label", lang],
      "Packed" -> StringRiffle[SourceVaultKGText[index[#], "Label", lang] & /@ s["Packed"], " / "],
      "Seconds" -> s["Seconds"], "Assets" -> Length[index[s["NodeId"]]["Assets"]],
      "Flags" -> StringRiffle[s["Flags"], ","]|>], plan["Slides"]]]]];

(* ---------------- \:53ef\:8996\:5316 (v1.30) ----------------
   \:8a71\:306e\:6d41\:308c (Story): \:7bc0\:3092\:8a71\:306e\:9806\:306b\:6a2a\:3078\:3001\:7bc0\:306e\:4e2d\:8eab\:3092\:7e26\:306b\:4e26\:3079\:3001\:5468\:8fba\:77e5\:8b58\:306f\:4e0b\:306e\:5e2f\:3002
   \:7bc0 (Sections): \:7bc0\:3092\:6a2a\:4e00\:5217\:306b\:4e26\:3079\:3001\:7bc0\:3092\:307e\:305f\:3050\:8fba\:3092\:5f27\:3067\:63cf\:304f (\:592a\:3055 = \:672c\:6570)\:3002
   \:5468\:8fba (Focus): \:9078\:3093\:3060\:30ce\:30fc\:30c9\:306e\:8fd1\:508d\:3092\:3070\:306d\:30e2\:30c7\:30eb\:3067\:3002\:5168\:4f53 (Graph): \:5168\:30ce\:30fc\:30c9\:3092\:3070\:306d\:30e2\:30c7\:30eb\:3067\:3002
   \:8272 = \:7a2e\:985e\:3001\:5927\:304d\:3055 = \:91cd\:8981\:5ea6\:3001\:5f62 = \:5c64 (\:672c\:6587 \:4e38\:30fb\:5468\:8fba\:77e5\:8b58 \:56db\:89d2\:30fb\:95a2\:9023\:7814\:7a76 \:83f1\:5f62)\:3001\:67a0 = \:72b6\:614b (\:8d64 = \:672a\:63a8\:6572\:3001\:9ed2\:306e\:592a\:67a0 = \:9078\:629e\:4e2d\:3001
   \:70b9\:7dda = \:8a08\:753b\:3067\:4ed6\:306e\:679a\:306b\:8a70\:3081\:8fbc\:307f)\:3001\:53f3\:4e0a\:306e\:70b9 = \:56f3\:30fb\:8868\:3042\:308a\:3001\:5de6\:4e0a\:306e\:70b9 = \:8cea\:7591\:5fdc\:7b54\:3042\:308a\:3001\:8584\:3044 = \:96a0\:3059\:30fb\:679d\:5208\:308a\:3002
   \:8a08\:753b\:3092\:91cd\:306d\:308b\:3068\:679a\:756a\:53f7 (#n) \:304c\:4ed8\:304f *)

$kgVizEdgeGroups = <|
  "Order" -> {"Precedes", "LeadsTo", "Derives", "Motivates"},
  "Prerequisite" -> {"Prerequisite"},
  "Support" -> {"Supports", "Explains"},
  "Related" -> {"Contrasts", "RelatedTo", "Cites"},
  "Contains" -> {"Contains"}|>;
$kgVizEdgeColors = <|
  "Order" -> GrayLevel[0.4], "Prerequisite" -> RGBColor[0.88, 0.49, 0.08], "Support" -> RGBColor[0.2, 0.55, 0.3],
  "Related" -> RGBColor[0.55, 0.42, 0.72], "Contains" -> GrayLevel[0.78]|>;
$kgVizEdgeDash = <|"Order" -> {}, "Prerequisite" -> {4, 3}, "Support" -> {}, "Related" -> {1, 3}, "Contains" -> {}|>;
$kgVizDirectedGroups = {"Order", "Prerequisite", "Support", "Contains"};

iKGVizEdgeGroup[kind_] := First[Keys[Select[$kgVizEdgeGroups, MemberQ[#, kind] &]], "Related"];
iKGVizEdgeStyle[g_String] := Directive @@ Join[
  {Lookup[$kgVizEdgeColors, g, GrayLevel[0.5]], AbsoluteThickness[If[g === "Contains", 0.6, 1.0]]},
  If[Lookup[$kgVizEdgeDash, g, {}] === {}, {}, {AbsoluteDashing[$kgVizEdgeDash[g]]}],
  If[MemberQ[{"Prerequisite", "Related"}, g], {Opacity[0.55]}, {}]];

(* EdgeKinds: \:7fa4\:306e\:540d\:524d (Order / Prerequisite / Support / Related / Contains) \:304b\:8fba\:306e\:7a2e\:985e\:306e\:540d\:524d\:306e\:30ea\:30b9\:30c8 *)
iKGVizGroups[spec_, default_List] := Which[
  spec === Automatic, default,
  spec === All, Keys[$kgVizEdgeGroups],
  ListQ[spec], DeleteDuplicates[Map[If[KeyExistsQ[$kgVizEdgeGroups, #], #, iKGVizEdgeGroup[#]] &, Select[spec, StringQ]]],
  True, default];

$kgVizKindColors = <|
  "Claim" -> RGBColor[0.88, 0.49, 0.08], "Conclusion" -> RGBColor[0.88, 0.49, 0.08], "Survey" -> RGBColor[0.88, 0.49, 0.08],
  "Section" -> GrayLevel[0.55],
  "Concept" -> RGBColor[0.33, 0.47, 0.68], "Definition" -> RGBColor[0.33, 0.47, 0.68], "Example" -> RGBColor[0.5, 0.64, 0.84],
  "Method" -> RGBColor[0.28, 0.56, 0.5], "Experiment" -> RGBColor[0.28, 0.56, 0.5],
  "Result" -> RGBColor[0.62, 0.11, 0.11], "Question" -> RGBColor[0.72, 0.56, 0.28],
  "Equation" -> RGBColor[0.45, 0.4, 0.72], "Figure" -> RGBColor[0.45, 0.4, 0.72],
  "Background" -> RGBColor[0.3, 0.64, 0.64], "RelatedWork" -> RGBColor[0.82, 0.44, 0.12],
  "Assumed" -> GrayLevel[0.78]|>;

iKGVizT[lang_, ja_String, en_String] := If[lang === "ja", ja, en];
iKGVizShort[s_String, k_Integer] := If[StringLength[s] > k, StringTake[s, k - 1] <> "\[Ellipsis]", s];
iKGVizShort[_, _] := "";

iKGVizSectionIds[kg_Association] := With[{root = Lookup[kg, "Root", "root"]},
  DeleteCases[DeleteDuplicates[Join[
    Lookup[Select[kg["Nodes"], Lookup[#, "Kind", ""] === "Section" &], "Id", {}],
    Lookup[Select[kg["Edges"], #["EdgeKind"] === "Contains" &], "From", {}]]], root]];

iKGVizPlanInfo[plan_] := If[! AssociationQ[plan], <||>,
  Module[{slides = Select[Replace[Lookup[plan, "Slides", {}], Except[_List] -> {}], AssociationQ], head = <||>, packed = <||>},
    MapIndexed[Function[{s, i},
        If[StringQ[Lookup[s, "NodeId", None]] && ! KeyExistsQ[head, s["NodeId"]], head[s["NodeId"]] = First[i]];
        Do[If[StringQ[p] && ! KeyExistsQ[packed, p], packed[p] = First[i]], {p, Replace[Lookup[s, "Packed", {}], Except[_List] -> {}]}]],
      slides];
    <|"Head" -> head, "Packed" -> packed,
      "Pruned" -> Replace[Lookup[plan, "Pruned", {}], Except[_List] -> {}],
      "Assumed" -> Replace[Lookup[plan, "Assumed", {}], Except[_List] -> {}],
      "Hidden" -> Replace[Lookup[plan, "Hidden", {}], Except[_List] -> {}],
      "Summary" -> Lookup[Select[slides, MemberQ[Replace[Lookup[#, "Flags", {}], Except[_List] -> {}], "Summary"] &], "NodeId", {}],
      "Partial" -> Lookup[Select[slides, MemberQ[Replace[Lookup[#, "Flags", {}], Except[_List] -> {}], "Partial"] &], "NodeId", {}],
      "Headings" -> Replace[Lookup[plan, "Headings", {}], Except[_List] -> {}]|>]];

(* \:30ce\:30fc\:30c9\:3054\:3068\:306e\:8868\:793a\:60c5\:5831 *)
iKGVizInfo[kg_Association, lang_String, planInfo_Association, selected_] := Module[
  {root = Lookup[kg, "Root", "root"], secs = iKGVizSectionIds[kg]},
  Association[Map[Function[n, Module[{id = n["Id"], layer = Lookup[n, "Layer", "Paper"], kind = Lookup[n, "Kind", "Concept"],
      pts = SourceVaultKGText[n, "Points", lang], text = Replace[Lookup[n, "Text", ""], Except[_String] -> ""],
      assets = Select[Replace[Lookup[n, "Assets", {}], Except[_List] -> {}], AssociationQ],
      qa = Replace[Lookup[n, "QA", {}], {s_String :> {s}, Except[_List] -> {}}], sectionQ, headQ, assumed, pruned, slide},
    sectionQ = MemberQ[secs, id] || id === root;
    headQ = sectionQ;
    slide = Lookup[Lookup[planInfo, "Head", <||>], id, None];
    assumed = MemberQ[Lookup[planInfo, "Assumed", {}], id];
    pruned = MemberQ[Lookup[planInfo, "Pruned", {}], id];
    id -> <|"Id" -> id, "Kind" -> kind, "Layer" -> layer,
      "Label" -> SourceVaultKGText[n, "Label", lang],
      "Importance" -> Replace[Lookup[n, "Importance", 0.5], Except[_?NumericQ] -> 0.5],
      "Section" -> sectionQ, "Root" -> id === root,
      "Group" -> Which[kind === "RelatedWork", "Related", layer =!= "Paper", "Background", True, "Paper"],
      "Shape" -> Which[headQ, "Header", kind === "RelatedWork", "Diamond", layer =!= "Paper", "Square", True, "Disk"],
      "ColorKey" -> Which[assumed, "Assumed", layer =!= "Paper" && kind =!= "RelatedWork", "Background", True, kind],
      "Unrefined" -> ! sectionQ && layer === "Paper" && StringTrim[text] =!= "" && ! MatchQ[pts, {__String}],
      "Hidden" -> TrueQ[Lookup[n, "Hidden", False]],
      "Assets" -> Length[assets] > 0, "AssetTypes" -> DeleteDuplicates[Lookup[assets, "Type", {}]],
      "QA" -> AnyTrue[qa, StringQ[#] && StringTrim[#] =!= "" &],
      "Slide" -> slide, "Packed" -> KeyExistsQ[Lookup[planInfo, "Packed", <||>], id] && slide === None,
      "PackedInto" -> Lookup[Lookup[planInfo, "Packed", <||>], id, None],
      "Pruned" -> pruned, "Assumed" -> assumed,
      "Faded" -> TrueQ[Lookup[n, "Hidden", False]] || pruned,
      "Selected" -> id === selected, "SummarySlide" -> MemberQ[Lookup[planInfo, "Summary", {}], id],
      "PartialSlide" -> MemberQ[Lookup[planInfo, "Partial", {}], id], "Heading" -> MemberQ[Lookup[planInfo, "Headings", {}], id],
      "Order" -> Replace[Lookup[n, "Order", None], Except[_?NumericQ] -> 10.^6]|>]],
    kg["Nodes"]]]];

iKGVizTip[n_Association, i_Association, lang_String] := Module[
  {pts = SourceVaultKGText[n, "Points", lang], lead = SourceVaultKGText[n, "Lead", lang],
   cite = SourceVaultKGText[n, "Cite", lang], text = Replace[Lookup[n, "Text", ""], Except[_String] -> ""], flags = {}},
  If[TrueQ[i["Unrefined"]], AppendTo[flags, iKGVizT[lang, "\:672a\:63a8\:6572 (\:8981\:70b9\:306a\:3057)", "not refined"]]];
  If[TrueQ[i["Hidden"]], AppendTo[flags, iKGVizT[lang, "\:96a0\:3059 (\:30b9\:30e9\:30a4\:30c9\:306b\:3057\:306a\:3044)", "hidden"]]];
  If[IntegerQ[i["Slide"]], AppendTo[flags, iKGVizT[lang, "\:8a08\:753b\:306e " <> ToString[i["Slide"]] <> " \:679a\:76ee", "slide " <> ToString[i["Slide"]]]]];
  If[IntegerQ[i["PackedInto"]] && ! IntegerQ[i["Slide"]],
    AppendTo[flags, iKGVizT[lang, ToString[i["PackedInto"]] <> " \:679a\:76ee\:306b\:8a70\:3081\:8fbc\:307f", "packed into slide " <> ToString[i["PackedInto"]]]]];
  If[TrueQ[i["Pruned"]], AppendTo[flags, iKGVizT[lang, "\:679d\:5208\:308a (\:6642\:9593\:306b\:5165\:3089\:306a\:3044)", "pruned"]]];
  If[TrueQ[i["Assumed"]], AppendTo[flags, iKGVizT[lang, "\:8074\:304d\:624b\:306f\:77e5\:3063\:3066\:3044\:308b (\:7701\:304f)", "assumed known"]]];
  If[i["AssetTypes"] =!= {}, AppendTo[flags, iKGVizT[lang, "\:56f3: ", "assets: "] <> StringRiffle[i["AssetTypes"], ", "]]];
  If[TrueQ[i["QA"]], AppendTo[flags, iKGVizT[lang, "\:8cea\:7591\:5fdc\:7b54\:3042\:308a", "has Q&A"]]];
  Framed[Pane[Column[Join[
      {Style[i["Label"], Bold, 12],
       Style[i["Id"] <> " \[CenterDot] " <> i["Kind"] <> " \[CenterDot] " <> i["Layer"] <> " \[CenterDot] " <> iKGVizT[lang, "\:91cd\:8981\:5ea6 ", "importance "] <>
         ToString[Round[i["Importance"], 0.01]], 9, GrayLevel[0.4]]},
      If[lead =!= "", {Style[lead, 10]}, {}],
      If[MatchQ[pts, {__String}], {Column[Style["\[Bullet] " <> #, 10] & /@ Take[pts, UpTo[6]], Spacings -> 0.1]}, {}],
      If[flags =!= {}, {Style[StringRiffle[flags, " / "], 9, RGBColor[0.55, 0.3, 0.1]]}, {}],
      If[cite =!= "", {Style[iKGVizT[lang, "\:51fa\:5178: ", "source: "] <> iKGVizShort[cite, 160], 9, GrayLevel[0.35]]}, {}],
      If[StringTrim[text] =!= "" && ! MatchQ[pts, {__String}], {Style[iKGVizShort[StringReplace[text, "\n" -> " "], 240], 9, GrayLevel[0.3]]}, {}]],
    Spacings -> 0.35], 380], Background -> White, FrameStyle -> GrayLevel[0.8], FrameMargins -> 6]];

(* \:30ce\:30fc\:30c9\:306e\:56f3\:5f62 (\:4f4d\:7f6e p\:3001\:534a\:5f84 r) *)
iKGVizPrim[p : {x_, y_}, r_, i_Association] := Module[{col, shape, outline, marks = {}},
  col = Lookup[$kgVizKindColors, i["ColorKey"], GrayLevel[0.5]];
  shape = Switch[i["Shape"],
    "Square", Rectangle[{x - r, y - r}, {x + r, y + r}],
    "Diamond", Polygon[{{x, y + 1.3 r}, {x + 1.3 r, y}, {x, y - 1.3 r}, {x - 1.3 r, y}}],
    "Header", Rectangle[{x - 1.7 r, y - 0.75 r}, {x + 1.7 r, y + 0.75 r}, RoundingRadius -> 0.35 r],
    _, Disk[p, r]];
  outline = Which[
    TrueQ[i["Selected"]], Directive[Black, AbsoluteThickness[2.6]],
    TrueQ[i["Unrefined"]], Directive[RGBColor[0.85, 0.1, 0.1], AbsoluteThickness[1.8]],
    TrueQ[i["Packed"]], Directive[GrayLevel[0.25], AbsoluteThickness[1.], AbsoluteDashing[{2, 2}]],
    IntegerQ[i["Slide"]], Directive[GrayLevel[0.1], AbsoluteThickness[1.4]],
    True, Directive[White, AbsoluteThickness[0.6]]];
  If[TrueQ[i["Assets"]], AppendTo[marks, {RGBColor[0.45, 0.4, 0.72], Disk[{x + 0.95 r, y + 0.95 r}, 0.38 r]}]];
  If[TrueQ[i["QA"]], AppendTo[marks, {RGBColor[0.82, 0.44, 0.12], Disk[{x - 0.95 r, y + 0.95 r}, 0.38 r]}]];
  {Opacity[If[TrueQ[i["Faded"]], 0.25, 1.]], EdgeForm[outline], FaceForm[col], shape, EdgeForm[None], marks}];

iKGVizLabelText[i_Association, k_Integer] := (If[IntegerQ[i["Slide"]], "#" <> ToString[i["Slide"]] <> " ", ""] <> iKGVizShort[i["Label"], k]);

iKGVizLabelQ[i_Association, mode_] := Which[
  mode === All, True,
  mode === None, TrueQ[i["Section"]],
  True, TrueQ[i["Section"]] || i["Importance"] >= 0.75 || IntegerQ[i["Slide"]] || TrueQ[i["Selected"]]];

(* \:30af\:30ea\:30c3\:30af\:3068\:30c4\:30fc\:30eb\:30c1\:30c3\:30d7\:3092\:4ed8\:3051\:305f\:30ce\:30fc\:30c9 *)
iKGVizNode[p_, r_, i_Association, n_Association, lang_, onClick_] := With[{prim = Tooltip[iKGVizPrim[p, r, i], iKGVizTip[n, i, lang]]},
  If[onClick === None, prim,
    With[{f = onClick, id = i["Id"]}, EventHandler[prim, {"MouseClicked" :> f[id]}]]]];

iKGVizEdgePrims[edges_List, coords_Association, info_Association, groups_List, radius_, lang_, sameColumn_, arrow_ : 0.006] := Module[{out = {}},
  Do[Module[{g = iKGVizEdgeGroup[e["EdgeKind"]], a = e["From"], b = e["To"], p1, p2, c, d, curve},
      If[MemberQ[groups, g] && KeyExistsQ[coords, a] && KeyExistsQ[coords, b] && a =!= b,
        p1 = coords[a]; p2 = coords[b]; d = p2 - p1;
        c = If[TrueQ[sameColumn] && Abs[d[[1]]] < 0.3,
          (p1 + p2)/2 + {0.35 + 0.18 * Abs[d[[2]]], 0},
          (p1 + p2)/2 + {0, 0.12 * Norm[d]}];
        curve = BezierCurve[{p1, c, p2}];
        AppendTo[out, Tooltip[
          {iKGVizEdgeStyle[g], Arrowheads[{{arrow, 1}}], If[MemberQ[$kgVizDirectedGroups, g], Arrow[curve, {radius[a], radius[b]}], curve]},
          e["EdgeKind"] <> ": " <> iKGVizShort[info[a]["Label"], 30] <> " \[RightArrow] " <> iKGVizShort[info[b]["Label"], 30]]]]],
    {e, edges}];
  out];

iKGVizRadius[i_Association] := If[TrueQ[i["Section"]], 0.2, 0.09 + 0.14 * Clip[i["Importance"], {0, 1}]];

(* ---- \:8a71\:306e\:6d41\:308c ---- *)
iKGVizStory[kg_, info_, index_, lang_, groups_, labels_, onClick_, keepQ_] := Module[
  {root = Lookup[kg, "Root", "root"], secs, parent, secOf, cols, colW = 2.6, rowH = 0.62, coords = <||>, maxRows = 0,
   bg, bandY, buckets = <||>, nodes, prims, edges, radius, xmax, ymin, colIndex, width},
  secs = SortBy[Select[iKGVizSectionIds[kg], KeyExistsQ[info, #] &], {info[#]["Order"] &, # &}];
  parent = Association[Map[#["To"] -> #["From"] &, Reverse[Select[kg["Edges"], #["EdgeKind"] === "Contains" &]]]];
  secOf[id_] := Module[{c = id, k = 0}, While[k < 30, c = Lookup[parent, c, None]; k++;
    Which[c === None, Return[None, Module], MemberQ[secs, c], Return[c, Module], c === root, Return[root, Module]]]; None];
  colIndex = Association[Join[{root -> 0}, MapIndexed[#1 -> First[#2] &, secs]]];
  (* \:5217: 0 = \:6839\:306e\:76f4\:4e0b\:30011.. = \:7bc0\:306e\:9806 *)
  cols = GroupBy[Select[Values[info], ! TrueQ[#["Section"]] && keepQ[#] &], With[{s = secOf[#["Id"]]}, If[s === None, None, s]] &];
  Do[coords[id] = {colW * colIndex[id], 0.}, {id, Keys[colIndex]}];
  KeyValueMap[Function[{s, members},
      If[s =!= None,
        With[{sorted = SortBy[members, {#["Order"] &, #["Id"] &}]},
          maxRows = Max[maxRows, Length[sorted]];
          Do[coords[sorted[[j, "Id"]]] = {colW * colIndex[s], -rowH * j}, {j, Length[sorted]}]]]],
    cols];
  (* \:5468\:8fba\:77e5\:8b58 (\:3069\:306e\:7bc0\:306b\:3082\:5165\:3089\:306a\:3044\:30ce\:30fc\:30c9): \:4e0b\:306e\:5e2f\:3002\:3064\:306a\:304c\:308b\:30ce\:30fc\:30c9\:306e\:5217\:306e\:5e73\:5747\:306e\:4f4d\:7f6e\:306b *)
  bg = Lookup[cols, Key[None], {}];
  bandY = -rowH * (maxRows + 1.6);
  Do[Module[{nbrs, xs, k},
      nbrs = Join[Lookup[Select[kg["Edges"], #["From"] === b["Id"] &], "To", {}], Lookup[Select[kg["Edges"], #["To"] === b["Id"] &], "From", {}]];
      xs = Lookup[coords, Select[nbrs, KeyExistsQ[coords, #] &]][[All, 1]];
      k = If[xs === {}, Length[secs] + 1, Round[Mean[xs]/colW]];
      buckets[k] = Append[Lookup[buckets, k, {}], b["Id"]]],
    {b, SortBy[bg, {#["Order"] &, #["Id"] &}]}];
  KeyValueMap[Function[{k, ids}, Do[coords[ids[[j]]] = {colW * k + 0.25, bandY - rowH * (j - 1)}, {j, Length[ids]}]], buckets];
  radius = Association[Map[#["Id"] -> iKGVizRadius[#] &, Values[info]]];
  xmax = colW * (Max[Append[Values[colIndex], 0]] + 2);
  width = Round[38 * (xmax + 0.8)];
  edges = iKGVizEdgePrims[kg["Edges"], coords, info, groups, radius, lang, True, 9./width];
  nodes = KeyValueMap[Function[{id, p},
      With[{i = info[id]}, {
        iKGVizNode[p, radius[id], i, index[id], lang, onClick],
        If[iKGVizLabelQ[i, labels],
          If[TrueQ[i["Section"]],
            Text[Style[iKGVizShort[If[TrueQ[i["Root"]], iKGVizT[lang, "(\:5168\:4f53) ", "(top) "], ""] <> i["Label"], 12], 8, Bold, GrayLevel[0.2]],
              p + {0, If[OddQ[Round[p[[1]]/colW]], 0.62, 0.3]}, {0, -1}],
            Text[Style[iKGVizLabelText[i, 12], 7, GrayLevel[0.15]], p + {radius[id] + 0.06, 0}, {-1, 0}]],
          Nothing]}]],
    coords];
  ymin = Min[Append[Values[coords][[All, 2]], 0.]] - rowH;
  prims = {edges, nodes,
    If[buckets =!= <||>, Text[Style[iKGVizT[lang, "\:5468\:8fba\:77e5\:8b58 (\:3069\:306e\:7bc0\:306b\:3082\:5165\:3089\:306a\:3044\:524d\:63d0)", "background (outside the sections)"], 9, Italic, GrayLevel[0.4]],
      {-0.3, bandY + 0.45}, {-1, 0}], Nothing]};
  Graphics[prims, PlotRange -> {{-0.8, xmax}, {ymin, 1.05}}, ImageSize -> width,
    ImagePadding -> 6, Background -> White]];

(* ---- \:7bc0\:306e\:6982\:89b3 (\:5f27\:306e\:56f3) ---- *)
iKGVizSections[kg_, info_, index_, lang_, groups_, onClick_] := Module[
  {root = Lookup[kg, "Root", "root"], secs, parent, secOf, members = <||>, x = <||>, gap = 1.7, cross = <||>, bgCount = <||>,
   prims = {}, bgX, maxC, up, down},
  secs = SortBy[Select[iKGVizSectionIds[kg], KeyExistsQ[info, #] &], {info[#]["Order"] &, # &}];
  parent = Association[Map[#["To"] -> #["From"] &, Reverse[Select[kg["Edges"], #["EdgeKind"] === "Contains" &]]]];
  secOf[id_] := Module[{c = id, k = 0}, If[MemberQ[secs, id], Return[id, Module]];
    While[k < 30, c = Lookup[parent, c, None]; k++;
      Which[c === None, Return[None, Module], MemberQ[secs, c], Return[c, Module], c === root, Return[root, Module]]]; None];
  Do[x[s] = gap * i, {s, secs}, {i, {Position[secs, s][[1, 1]]}}];
  x[root] = 0.;
  bgX = gap * (Length[secs] + 1);
  Do[With[{s = secOf[id]}, members[s] = Append[Lookup[members, Key[s], {}], id]], {id, Keys[info]}];
  Do[Module[{g = iKGVizEdgeGroup[e["EdgeKind"]], sa = secOf[e["From"]], sb = secOf[e["To"]]},
      If[MemberQ[groups, g] && g =!= "Contains",
        Which[
          sa =!= None && sb =!= None && sa =!= sb, cross[{sa, sb}] = Append[Lookup[cross, Key[{sa, sb}], {}], g],
          sa === None && sb =!= None, bgCount[sb] = Lookup[bgCount, sb, 0] + 1,
          sb === None && sa =!= None, bgCount[sa] = Lookup[bgCount, sa, 0] + 1]]],
    {e, kg["Edges"]}];
  maxC = Max[1, Max[Append[Length /@ Values[cross], 1]]];
  up = 0.5; down = 0.5;
  KeyValueMap[Function[{pair, gs}, Module[{xa = x[pair[[1]]], xb = x[pair[[2]]], g = First[Commonest[gs]]},
      AppendTo[prims, Tooltip[{Lookup[$kgVizEdgeColors, g, GrayLevel[0.5]], Opacity[0.7],
          AbsoluteThickness[0.8 + 4 * Length[gs]/maxC],
          Arrowheads[{{0.008, 1}}],
          Arrow[BezierCurve[{{xa, 0.25}, {(xa + xb)/2, (up = Max[up, 0.3 + 0.2 * Abs[xb - xa]]; 0.3 + 0.2 * Abs[xb - xa])}, {xb, 0.25}}]]},
        info[pair[[1]]]["Label"] <> " \[RightArrow] " <> info[pair[[2]]]["Label"] <> ": " <> ToString[Length[gs]] <> iKGVizT[lang, " \:672c (", " edges ("] <>
          StringRiffle[KeyValueMap[#1 <> " " <> ToString[#2] &, Counts[gs]], ", "] <> ")"]]]],
    cross];
  KeyValueMap[Function[{s, c}, AppendTo[prims, Tooltip[{RGBColor[0.3, 0.64, 0.64], Opacity[0.6], AbsoluteThickness[0.8 + Min[c, 12]/2.],
        BezierCurve[{{bgX, -0.25}, {(bgX + x[s])/2, (down = Max[down, 0.3 + 0.12 * Abs[bgX - x[s]]]; -0.3 - 0.12 * Abs[bgX - x[s]])}, {x[s], -0.25}}]},
      iKGVizT[lang, "\:5468\:8fba\:77e5\:8b58 \:3068\:306e\:8fba ", "background edges "] <> ToString[c]]]],
    Select[bgCount, # > 0 &]];
  Do[Module[{ids = DeleteCases[Lookup[members, Key[s], {}], s], i = info[s], nUn, nFig, nQA, r},
      nUn = Count[info /@ ids, j_ /; TrueQ[j["Unrefined"]]];
      nFig = Count[info /@ ids, j_ /; TrueQ[j["Assets"]]];
      nQA = Count[info /@ ids, j_ /; TrueQ[j["QA"]]];
      r = 0.12 + 0.05 * Sqrt[Length[ids]];
      AppendTo[prims, {
        With[{prim = Tooltip[{EdgeForm[If[nUn > 0, Directive[RGBColor[0.85, 0.1, 0.1], AbsoluteThickness[2]],
              If[TrueQ[i["Selected"]], Directive[Black, AbsoluteThickness[2.6]], Directive[White]]]],
            FaceForm[If[TrueQ[i["Root"]], $kgVizKindColors["Claim"], GrayLevel[0.55]]], Disk[{x[s], 0}, Min[r, 0.7]]},
          Column[{Style[i["Label"], Bold, 12],
            Style[SourceVaultKGText[index[s], "Summary", lang], 10],
            Style[iKGVizT[lang, "\:30ce\:30fc\:30c9 ", "nodes "] <> ToString[Length[ids]] <> iKGVizT[lang, " / \:56f3 ", " / figures "] <> ToString[nFig] <>
              iKGVizT[lang, " / \:8cea\:7591\:5fdc\:7b54 ", " / Q&A "] <> ToString[nQA] <> iKGVizT[lang, " / \:672a\:63a8\:6572 ", " / unrefined "] <> ToString[nUn], 9, GrayLevel[0.35]]},
            Spacings -> 0.3]]},
          If[onClick === None, prim, With[{f = onClick, id = s}, EventHandler[prim, {"MouseClicked" :> f[id]}]]]],
        Text[Style[iKGVizShort[i["Label"], 14] <> " (" <> ToString[Length[ids]] <> ")", 8, GrayLevel[0.15]], {x[s], -0.05 - Min[r, 0.7]}, {-1, 0}, {0, -1}]}]],
    {s, Prepend[secs, root]}];
  With[{nbg = Length[Lookup[members, Key[None], {}]]},
    If[nbg > 0,
      AppendTo[prims, {Tooltip[{FaceForm[$kgVizKindColors["Background"]], EdgeForm[White],
          Rectangle[{bgX - 0.25, -0.25}, {bgX + 0.25, 0.25}]}, iKGVizT[lang, "\:5468\:8fba\:77e5\:8b58 ", "background "] <> ToString[nbg]],
        Text[Style[iKGVizT[lang, "\:5468\:8fba\:77e5\:8b58 (", "background ("] <> ToString[nbg] <> ")", 8, GrayLevel[0.15]], {bgX, -0.35}, {-1, 0}, {0, -1}]}]]];
  Graphics[prims, PlotRange -> {{-0.9, bgX + 0.9}, {-Max[down / 2 + 0.2, 2.4], up / 2 + 0.4}},
    ImageSize -> Round[44 * (bgX + 1.8)], ImagePadding -> 6, Background -> White]];

(* ---- \:5468\:8fba / \:5168\:4f53 (\:3070\:306d\:30e2\:30c7\:30eb) ---- *)
iKGVizSpring[kg_, info_, index_, lang_, groups_, labels_, onClick_, ids_List, focus_] := Module[{es, radius, g},
  es = Select[kg["Edges"], MemberQ[ids, #["From"]] && MemberQ[ids, #["To"]] && #["From"] =!= #["To"] &&
    MemberQ[groups, iKGVizEdgeGroup[#["EdgeKind"]]] &];
  radius = Association[Map[# -> 0.6 * iKGVizRadius[info[#]] &, ids]];
  g = Graph[ids, UndirectedEdge[#["From"], #["To"]] & /@ es, GraphLayout -> "SpringElectricalEmbedding"];
  With[{coords = AssociationThread[VertexList[g], GraphEmbedding[g]]},
    Graphics[{
      iKGVizEdgePrims[es, coords, info, groups, radius, lang, False, If[Length[ids] <= 40, 9./700, 9./1100]],
      KeyValueMap[Function[{id, p}, With[{i = info[id]}, {
          iKGVizNode[p, radius[id], i, index[id], lang, onClick],
          If[iKGVizLabelQ[i, labels] || id === focus || Length[ids] <= 40,
            Text[Style[iKGVizLabelText[i, 16], If[id === focus, 9, 7], If[id === focus, Bold, Plain], GrayLevel[0.15]],
              p + {0, -radius[id] - 0.04}, {0, 1}], Nothing]}]],
        coords]},
      ImageSize -> If[Length[ids] <= 40, 700, 1100], ImagePadding -> 10, Background -> White]]];

(* ---- v1.44: \:968e\:5c64 (\:9806\:5e8f\:6728\:3092 1 \:30ce\:30fc\:30c9 1 \:884c\:3067\:3001\:6df1\:3055\:3067\:5b57\:4e0b\:3052) ----
   \:30b9\:30e9\:30a4\:30c9\:306f\:9806\:5e8f\:6728\:3092\:524d\:304b\:3089\:305f\:3069\:3063\:3066\:4f5c\:308b\:306e\:3067\:3001\:305d\:306e\:6728\:305d\:306e\:3082\:306e\:3092\:898b\:305b\:308b\:3002\:5404\:884c = \:984c\:76ee \:2014 \:4e00\:884c\:8981\:7d04 [\:898b\:3048\:308b\:5b50\:306e\:6570, \:7573\:3093\:3060\:8449\:306e\:6570]\:3002
   \:5b50\:304c "MaxDegree" \:3092\:8d85\:3048\:308b\:30ce\:30fc\:30c9\:306f\:8d64\:3002\:307e\:3068\:307e\:308a (Cluster) \:306f\:5b9f\:7dda\:3001\:4fdd\:5b58\:524d\:306e\:4e0b\:898b (\:6a5f\:68b0\:7684\:306a\:307e\:3068\:3081) \:306f\:70b9\:7dda\:306e\:67a0\:3002
   \:8449 (\:5b50\:306e\:7121\:3044\:30ce\:30fc\:30c9) \:306f\:7573\:3080 ("Labels" -> All \:3067\:51fa\:3059)\:3002\:8a08\:753b\:3092\:91cd\:306d\:308b\:3068\:884c\:982d\:306b #n *)
iKGVizHierarchy[kg_, info_, index_, lang_, onClick_, d_Integer, treeIn_, leavesQ_, previewIds_List] := Module[
  {tree, root, vis, kids, degOf, place, row = 0, xs = <||>, ys = <||>, shown = {}, prims = {}, viol = {}, maxDeg = 0, maxX = 0,
   w = 860, header, rows},
  tree = treeIn;
  If[! AssociationQ[tree], Return[Style[iKGVizT[lang, "\:9806\:5e8f\:6728\:3092\:4f5c\:308c\:307e\:305b\:3093", "Cannot build the ordered tree"], RGBColor[0.7, 0.1, 0.1]]]];
  root = tree["Root"];
  vis[id_] := iKGVisibleQ[index, id];
  degOf[id_] := Length[Select[Lookup[tree["Children"], id, {}], vis]];
  kids[id_] := With[{c = Lookup[tree["Children"], id, {}]}, If[TrueQ[leavesQ], c, Select[c, Lookup[tree["Children"], #, {}] =!= {} &]]];
  place[id_, dep_] := (xs[id] = 1.2 * dep; ys[id] = -row; row++; AppendTo[shown, id]; maxX = Max[maxX, 1.2 * dep];
    Scan[place[#, dep + 1] &, kids[id]]);
  place[root, 0];
  rows = Max[row, 1];
  Do[With[{ks = kids[id]}, If[ks =!= {}, With[{xp = xs[id], yp = ys[id]},
      AppendTo[prims, {GrayLevel[0.72], AbsoluteThickness[0.8],
        Line[{{xp, yp - 0.4}, {xp, ys[Last[ks]]}}],
        Map[Line[{{xp, ys[#]}, {xs[#] - 0.36, ys[#]}}] &, ks]}]]]], {id, shown}];
  Do[Module[{i = info[id], k = degOf[id], leaves, lab, over, prev = MemberQ[previewIds, id], gist, p = {xs[id], ys[id]}},
      maxDeg = Max[maxDeg, k];
      over = k > d;
      If[over, AppendTo[viol, id]];
      leaves = Length[Select[Lookup[tree["Children"], id, {}], vis[#] && Lookup[tree["Children"], #, {}] === {} &]];
      gist = SourceVaultKGText[index[id], "Gist", lang];
      lab = iKGVizLabelText[i, 30] <> If[gist =!= "", " \[LongDash] " <> iKGVizShort[gist, 32], ""] <>
        If[k > 0, "  [" <> iKGVizT[lang, "\:5b50 " <> ToString[k], ToString[k] <> " children"] <>
          If[! TrueQ[leavesQ] && leaves > 0, iKGVizT[lang, ", \:3046\:3061\:8449 ", ", leaves "] <> ToString[leaves], ""] <> "]", ""] <>
        If[over, iKGVizT[lang, "  \:4e0a\:9650 " <> ToString[d] <> " \:3092\:8d85\:3048\:308b", "  over the bound " <> ToString[d]], ""] <>
        Which[TrueQ[i["PartialSlide"]], iKGVizT[lang, "  (\:6982\:8981 1 \:679a + \:4e00\:90e8\:3092\:8a73\:3057\:304f)", "  (summary + some detail)"],
          TrueQ[i["SummarySlide"]], iKGVizT[lang, "  (\:6982\:8981 1 \:679a)", "  (summary slide)"],
          TrueQ[i["Heading"]], iKGVizT[lang, "  (\:898b\:51fa\:3057\:306e\:307f: \:5b50\:3092\:679a\:306b)", "  (heading only)"], True, ""];
      AppendTo[prims, {
        If[TrueQ[Lookup[Lookup[index, id, <||>], "Cluster", False]] || prev,
          {EdgeForm[Directive[RGBColor[0.45, 0.52, 0.3], AbsoluteThickness[1.6], AbsoluteDashing[If[prev, {3, 2}, {}]]]], FaceForm[None],
            Rectangle[p - {0.55, 0.42}, p + {0.55, 0.42}, RoundingRadius -> 0.12]}, {}],
        iKGVizNode[p, 0.3, i, index[id], lang, onClick],
        Text[Style[lab, 9, If[over, RGBColor[0.8, 0.1, 0.1], GrayLevel[0.15]], If[over || TrueQ[i["Section"]], Bold, Plain]],
          p + {0.7, 0}, {-1, 0}]}]],
    {id, shown}];
  header = Style[Row[{
      If[SourceVaultKGTocQ[kg], Switch[Lookup[kg["Toc"], "Method", ""],
        "LLM", iKGVizT[lang, "\:76ee\:6b21 (\:30dc\:30c8\:30e0\:30a2\:30c3\:30d7\:306b\:69cb\:7bc9) / ", "table of contents (built bottom-up) / "],
        "Preview", iKGVizT[lang, "\:76ee\:6b21\:306e\:4e0b\:898b (\:8cc7\:6599\:306e\:69cb\:9020\:304b\:3089\:6a5f\:68b0\:7684\:306b\:3002\:4fdd\:5b58\:524d) / ", "contents preview (mechanical, unsaved) / "],
        _, iKGVizT[lang, "\:76ee\:6b21 (\:8cc7\:6599\:306e\:69cb\:9020\:304b\:3089\:6a5f\:68b0\:7684\:306b) / ", "table of contents (mechanical) / "]], ""],
      iKGVizT[lang, "\:5b50\:306e\:6570\:306e\:4e0a\:9650 ", "max children "], d, iKGVizT[lang, " / \:3044\:307e\:306e\:6700\:5927 ", " / largest now "], maxDeg,
      If[viol =!= {}, iKGVizT[lang, " / \:8d85\:3048\:3066\:3044\:308b\:30ce\:30fc\:30c9 ", " / over the bound: "] <> ToString[Length[viol]], ""],
      If[previewIds =!= {}, iKGVizT[lang, " / \:70b9\:7dda = \:4fdd\:5b58\:524d\:306e\:6a5f\:68b0\:7684\:306a\:307e\:3068\:3081 (\:300c\:968e\:5c64\:5316\:300d\:3067 LLM \:306e\:5206\:3051\:65b9\:3068\:4e00\:884c\:8981\:7d04\:306b\:3057\:3066\:4fdd\:5b58)",
        " / dashed = unsaved mechanical grouping (Hierarchy saves it with the LLM's grouping and summaries)"], ""],
      If[! TrueQ[leavesQ], iKGVizT[lang, " / \:8449\:306f\:7573\:3093\:3067\:3044\:308b (\:540d\:524d: \:3059\:3079\:3066 \:3067\:8868\:793a)", " / leaves folded (labels: all to show)"], ""]}], 10, GrayLevel[0.3]];
  Labeled[Graphics[prims, PlotRange -> {{-0.8, Max[maxX + 14, (w - 20) / 20.]}, {-rows + 0.4, 0.8}},
      ImageSize -> {w, Max[120, Round[22 * (rows + 1)]]}, AspectRatio -> Full, ImagePadding -> 6, Background -> White],
    header, Top]];

Options[SourceVaultKGVisualize] = {"View" -> "Story", "Focus" -> None, "Radius" -> 1, "EdgeKinds" -> Automatic,
  "Layers" -> All, "Labels" -> Automatic, "Plan" -> None, "Selected" -> None, "OnClick" -> None,
  "Language" -> Automatic, "Legend" -> True, "Hidden" -> True, "MaxDegree" -> 5, "Strategy" -> "Source", "Balance" -> Automatic};
SourceVaultKGVisualize[kg_Association, OptionsPattern[]] := Module[
  {lang = Replace[OptionValue["Language"], Automatic -> Lookup[kg, "Language", "ja"]], view = OptionValue["View"],
   info, index, groups, layers, keepQ, g, planInfo, focus = OptionValue["Focus"], ids},
  If[! ListQ[Lookup[kg, "Nodes", None]] || kg["Nodes"] === {}, Return[Failure["NoNodes", <|"MessageTemplate" -> "the graph has no nodes"|>]]];
  index = iKGNodeIndex[kg];
  planInfo = iKGVizPlanInfo[OptionValue["Plan"]];
  info = iKGVizInfo[kg, lang, planInfo, OptionValue["Selected"]];
  layers = Replace[OptionValue["Layers"], All -> {"Paper", "Background", "Related"}];
  If[! ListQ[layers], layers = {"Paper", "Background", "Related"}];
  keepQ = Function[i, (TrueQ[i["Section"]] || MemberQ[layers, i["Group"]]) &&
    (TrueQ[OptionValue["Hidden"]] || ! TrueQ[i["Hidden"]])];
  g = Switch[view,
    "Hierarchy",
      (* \:76ee\:6b21\:304c\:3042\:308c\:3070\:305d\:306e\:6728\:3002\:7121\:3051\:308c\:3070\:8cc7\:6599\:306e\:69cb\:9020\:304b\:3089\:6a5f\:68b0\:7684\:306b\:4f5c\:3063\:305f\:76ee\:6b21\:3092\:4fdd\:5b58\:305b\:305a\:306b\:4e0b\:898b\:3068\:3057\:3066\:63cf\:304f ("Balance" -> False \:3067\:8cc7\:6599\:306e\:6728\:306e\:307e\:307e) *)
      Module[{d = Replace[OptionValue["MaxDegree"], Except[_Integer?(# >= 2 &)] -> 5], st = OptionValue["Strategy"], kgShow = kg, prevIds = {}, m},
        If[! StringQ[st], st = "Source"];
        If[! SourceVaultKGTocQ[kg] && OptionValue["Balance"] =!= False,
          m = Quiet @ Check[SourceVaultKGMechanicalToc[kg, "MaxDegree" -> d, "Strategy" -> st], $Failed];
          If[AssociationQ[m], kgShow = m["KG"]; kgShow["Toc"] = Append[kgShow["Toc"], "Method" -> "Preview"];
            prevIds = Join[m["Preview"], m["Added"]]]];
        iKGVizHierarchy[kgShow, iKGVizInfo[kgShow, lang, planInfo, OptionValue["Selected"]], iKGNodeIndex[kgShow], lang,
          OptionValue["OnClick"], d, SourceVaultKGOrderedTree[kgShow, "Strategy" -> st], OptionValue["Labels"] === All, prevIds]],
    "Sections",
      iKGVizSections[kg, info, index, lang, iKGVizGroups[OptionValue["EdgeKinds"], {"Order", "Prerequisite", "Support", "Related"}],
        OptionValue["OnClick"]],
    "Focus",
      If[! (StringQ[focus] && KeyExistsQ[info, focus]),
        Return[Failure["NoFocus", <|"MessageTemplate" -> "choose a node to focus on (\"Focus\" -> id)"|>]]];
      With[{gs = iKGVizGroups[OptionValue["EdgeKinds"], Keys[$kgVizEdgeGroups]]},
        ids = Select[VertexList[NeighborhoodGraph[
          Graph[Keys[info], UndirectedEdge[#["From"], #["To"]] & /@ Select[kg["Edges"],
            MemberQ[gs, iKGVizEdgeGroup[#["EdgeKind"]]] && #["From"] =!= #["To"] &]],
          focus, Max[1, Min[3, Replace[OptionValue["Radius"], Except[_Integer] -> 1]]]]], keepQ[info[#]] || # === focus &];
        info[focus] = Append[info[focus], "Selected" -> True];
        iKGVizSpring[kg, info, index, lang, gs, OptionValue["Labels"], OptionValue["OnClick"], ids, focus]],
    "Graph",
      With[{gs = iKGVizGroups[OptionValue["EdgeKinds"], {"Order", "Prerequisite", "Support", "Related", "Contains"}]},
        iKGVizSpring[kg, info, index, lang, gs, OptionValue["Labels"], OptionValue["OnClick"],
          Select[Keys[info], keepQ[info[#]] &], None]],
    _,
      iKGVizStory[kg, info, index, lang, iKGVizGroups[OptionValue["EdgeKinds"], {"Order", "Prerequisite", "Support"}],
        OptionValue["Labels"], OptionValue["OnClick"], keepQ]];
  If[TrueQ[OptionValue["Legend"]], Labeled[g, SourceVaultKGLegend[lang], Bottom], g]];
SourceVaultKGVisualize[_, ___] := Failure["NotAGraph", <|"MessageTemplate" -> "expected a knowledge graph Association"|>];

SourceVaultKGLegend[lang_String : "ja", perRow_Integer : 0] := Module[{sw, kinds, edges, marks, rows},
  sw[col_, shape_] := Graphics[{FaceForm[col], EdgeForm[White], Switch[shape,
      "Square", Rectangle[{-0.8, -0.8}, {0.8, 0.8}], "Diamond", Polygon[{{0, 1}, {1, 0}, {0, -1}, {-1, 0}}],
      "Header", Rectangle[{-1.3, -0.6}, {1.3, 0.6}, RoundingRadius -> 0.3], _, Disk[]]}, ImageSize -> 12];
  kinds = {
    {sw[$kgVizKindColors["Claim"], "Disk"], iKGVizT[lang, "\:4e3b\:5f35\:30fb\:7d50\:8ad6", "claim"]},
    {sw[$kgVizKindColors["Section"], "Header"], iKGVizT[lang, "\:7bc0", "section"]},
    {sw[$kgVizKindColors["Concept"], "Disk"], iKGVizT[lang, "\:6982\:5ff5\:30fb\:5b9a\:7fa9", "concept"]},
    {sw[$kgVizKindColors["Method"], "Disk"], iKGVizT[lang, "\:65b9\:6cd5\:30fb\:5b9f\:9a13", "method"]},
    {sw[$kgVizKindColors["Result"], "Disk"], iKGVizT[lang, "\:7d50\:679c", "result"]},
    {sw[$kgVizKindColors["Figure"], "Disk"], iKGVizT[lang, "\:5f0f\:30fb\:56f3", "equation/figure"]},
    {sw[$kgVizKindColors["Question"], "Disk"], iKGVizT[lang, "\:554f\:3044", "question"]},
    {sw[$kgVizKindColors["Background"], "Square"], iKGVizT[lang, "\:5468\:8fba\:77e5\:8b58", "background"]},
    {sw[$kgVizKindColors["RelatedWork"], "Diamond"], iKGVizT[lang, "\:95a2\:9023\:7814\:7a76", "related work"]}};
  edges = Map[{Graphics[{iKGVizEdgeStyle[#[[1]]], AbsoluteThickness[1.8], Arrowheads[0.3],
        If[MemberQ[$kgVizDirectedGroups, #[[1]]], Arrow[{{0, 0}, {1, 0}}], Line[{{0, 0}, {1, 0}}]]},
      ImageSize -> {28, 10}, PlotRange -> {{-0.05, 1.05}, {-0.2, 0.2}}, AspectRatio -> Full], #[[2]]} &,
    {{"Order", iKGVizT[lang, "\:9806\:5e8f", "order"]}, {"Prerequisite", iKGVizT[lang, "\:524d\:63d0", "prerequisite"]},
     {"Support", iKGVizT[lang, "\:652f\:3048", "support"]}, {"Related", iKGVizT[lang, "\:5bfe\:6bd4\:30fb\:95a2\:9023", "related"]},
     {"Contains", iKGVizT[lang, "\:5305\:542b", "contains"]}}];
  marks = {
    {Graphics[{FaceForm[GrayLevel[0.85]], EdgeForm[Directive[RGBColor[0.85, 0.1, 0.1], AbsoluteThickness[1.8]]], Disk[]}, ImageSize -> 12], iKGVizT[lang, "\:672a\:63a8\:6572", "unrefined"]},
    {Graphics[{FaceForm[GrayLevel[0.85]], EdgeForm[Directive[Black, AbsoluteThickness[2.4]]], Disk[]}, ImageSize -> 12], iKGVizT[lang, "\:9078\:629e\:4e2d", "selected"]},
    {Graphics[{FaceForm[GrayLevel[0.85]], EdgeForm[Directive[GrayLevel[0.25], AbsoluteDashing[{2, 2}]]], Disk[]}, ImageSize -> 12], iKGVizT[lang, "\:8a70\:3081\:8fbc\:307f", "packed"]},
    {Graphics[{FaceForm[GrayLevel[0.85]], Disk[], RGBColor[0.45, 0.4, 0.72], Disk[{0.9, 0.9}, 0.4]}, ImageSize -> 12], iKGVizT[lang, "\:56f3\:30fb\:8868\:3042\:308a", "has figure"]},
    {Graphics[{FaceForm[GrayLevel[0.85]], Disk[], RGBColor[0.82, 0.44, 0.12], Disk[{-0.9, 0.9}, 0.4]}, ImageSize -> 12], iKGVizT[lang, "\:8cea\:7591\:5fdc\:7b54\:3042\:308a", "has Q&A"]},
    {Graphics[{Opacity[0.25], GrayLevel[0.3], Disk[]}, ImageSize -> 12], iKGVizT[lang, "\:96a0\:3059\:30fb\:679d\:5208\:308a", "hidden/pruned"]},
    {Style["#n", 8], iKGVizT[lang, "\:8a08\:753b\:306e\:679a\:756a\:53f7", "slide no. in the plan"]}};
  rows = If[perRow > 0, Flatten[Map[Partition[#, UpTo[perRow]] &, {kinds, edges, marks}], 1], {kinds, edges, marks}];
  Column[Map[Row[Riffle[Map[Row[{#[[1]], " ", Style[#[[2]], 8]}] &, #], Spacer[10]]] &, rows], Spacings -> 0.4]];

End[]

EndPackage[]

(*Print[Style["SourceVault_knowledgegraph.wl \:304c\:30ed\:30fc\:30c9\:3055\:308c\:307e\:3057\:305f\:3002", Bold]];
Print["
  SourceVaultKGFromJSON[json] / SourceVaultKGMerge[kg, delta]      \[RightArrow] LLM \:5fdc\:7b54\:306e\:53d6\:308a\:8fbc\:307f (\:691c\:8a3c\:3064\:304d)
  SourceVaultKGSave / Load / List[]                                  \[RightArrow] <root>/knowledgegraph/graphs/
  SourceVaultKGAudience[spec] / SourceVaultKGScores[kg, aud]         \[RightArrow] \:8074\:304d\:624b\:30e2\:30c7\:30eb\:3068\:5fc5\:8981\:5ea6
  SourceVaultKGOrderedTree[kg] / OrderedTrees / Verify               \[RightArrow] \:6700\:5c0f\:5168\:57df\:9806\:5e8f\:6728\:3068\:7834\:7dbb\:691c\:8a3c
  SourceVaultKGPlan[kg, tree, \"Slides\"->n, \"Audience\"->..]        \[RightArrow] \:8a70\:3081\:8fbc\:307f\:30fb\:679d\:5208\:308a\:8a08\:753b
  SourceVaultKGOutline[kg, plan] / OutlineToMarkdown                 \[RightArrow] \:8a00\:8a9e\:5225\:30a2\:30a6\:30c8\:30e9\:30a4\:30f3 \[RightArrow] \:30b7\:30ca\:30ea\:30aa md
  SourceVaultKGCompose[{kg1, kg2}] / BackgroundLink / SuggestPastSlides
  SourceVaultKGGraph / View / TreeView / PlanView / ToTopicItemGraph
"];*)
