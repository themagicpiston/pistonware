--[[ tarmac.lua - block icon/side asset ids, keyed by block name.
BedWars removed its in-game `require(replicatedStorage.TS.tarmac).blocks` table, so the
data it used to expose is shipped here directly. The Scaffold "Block Count" widget looks
up ["icon"] for each block; ["s"]/["td"]/etc. are the other faces, kept for completeness. ]]
return {
	["andesite"] = {
		["icon"] = "rbxassetid://9072552631",
		["s"] = "rbxassetid://9072525162"
	},
	["andesite_polished"] = {
		["icon"] = "rbxassetid://9072552793",
		["s"] = "rbxassetid://9072552916"
	},
	["aquamarine_lantern"] = {
		["icon"] = "rbxassetid://12948863284",
		["s"] = "rbxassetid://12946930317"
	},
	["barrel"] = {
		["icon"] = "rbxassetid://14968393558",
		["s"] = "rbxassetid://14968393626",
		["td"] = "rbxassetid://14968393691"
	},
	["barrier"] = {
		["icon"] = "rbxassetid://10569969807",
		["s"] = "rbxassetid://10569969967"
	},
	["bedrock"] = {
		["icon"] = "rbxassetid://9207283973",
		["s"] = "rbxassetid://9207284200"
	},
	["birch_log"] = {
		["icon"] = "rbxassetid://7884365859",
		["s"] = "rbxassetid://16991765391",
		["td"] = "rbxassetid://16991765432"
	},
	["blue_tile"] = {
		["s"] = "rbxassetid://16238617352"
	},
	["bookshelf"] = {
		["icon"] = "rbxassetid://10866360547",
		["s"] = "rbxassetid://10866119486",
		["td"] = "rbxassetid://10866360672"
	},
	["brick"] = {
		["icon"] = "rbxassetid://7884366460",
		["s"] = "rbxassetid://12948863341"
	},
	["ceramic"] = {
		["icon"] = "rbxassetid://7884366622",
		["s"] = "rbxassetid://16991765474"
	},
	["christmas_drawbridge"] = {
		["icon"] = "rbxassetid://122137461128449",
		["s"] = "rbxassetid://97798420366864"
	},
	["christmas_scaffold"] = {
		["icon"] = "rbxassetid://116346363779293",
		["s"] = "rbxassetid://127832405061521",
		["td"] = "rbxassetid://140661205602211"
	},
	["clay"] = {
		["icon"] = "rbxassetid://7884366829",
		["s"] = "rbxassetid://7861526072"
	},
	["clay_black"] = {
		["icon"] = "rbxassetid://7884367004",
		["s"] = "rbxassetid://16991765519"
	},
	["clay_blue"] = {
		["icon"] = "rbxassetid://7884367119",
		["s"] = "rbxassetid://16991765574"
	},
	["clay_cyan"] = {
		["icon"] = "rbxassetid://7884367212",
		["s"] = "rbxassetid://16991765629"
	},
	["clay_dark_brown"] = {
		["icon"] = "rbxassetid://7884367299",
		["s"] = "rbxassetid://16991765722"
	},
	["clay_dark_green"] = {
		["icon"] = "rbxassetid://7884367424",
		["s"] = "rbxassetid://16991765812"
	},
	["clay_gray"] = {
		["icon"] = "rbxassetid://7884367563",
		["s"] = "rbxassetid://16991765869"
	},
	["clay_green"] = {
		["icon"] = "rbxassetid://7884367698",
		["s"] = "rbxassetid://16991765938"
	},
	["clay_light_brown"] = {
		["icon"] = "rbxassetid://7884367792",
		["s"] = "rbxassetid://7872905675"
	},
	["clay_light_green"] = {
		["icon"] = "rbxassetid://7884367872",
		["s"] = "rbxassetid://7872906008"
	},
	["clay_orange"] = {
		["icon"] = "rbxassetid://7884367973",
		["s"] = "rbxassetid://16991766008"
	},
	["clay_pink"] = {
		["icon"] = "rbxassetid://7884368035",
		["s"] = "rbxassetid://16991766060"
	},
	["clay_purple"] = {
		["icon"] = "rbxassetid://7884368099",
		["s"] = "rbxassetid://16991766106"
	},
	["clay_red"] = {
		["icon"] = "rbxassetid://7884368246",
		["s"] = "rbxassetid://16991766155"
	},
	["clay_tan"] = {
		["icon"] = "rbxassetid://7884368312",
		["s"] = "rbxassetid://16991766219"
	},
	["clay_white"] = {
		["icon"] = "rbxassetid://7884368439",
		["s"] = "rbxassetid://16991766265"
	},
	["clay_yellow"] = {
		["icon"] = "rbxassetid://7884368673",
		["s"] = "rbxassetid://16991766313"
	},
	["cobblestone"] = {
		["icon"] = "rbxassetid://8296848529",
		["s"] = "rbxassetid://8296848659"
	},
	["concrete_green"] = {
		["icon"] = "rbxassetid://8537949134",
		["s"] = "rbxassetid://8537949581"
	},
	["copper_block"] = {
		["icon"] = "rbxassetid://10859696115",
		["s"] = "rbxassetid://10859696172"
	},
	["cosmic_lucky_block"] = {
		["icon"] = "rbxassetid://11773163557",
		["s"] = "rbxassetid://11773163645"
	},
	["diamond_block"] = {
		["icon"] = "rbxassetid://7884368860",
		["s"] = "rbxassetid://7861529819"
	},
	["diamond_ore"] = {
		["icon"] = "rbxassetid://105644572237110",
		["s"] = "rbxassetid://117384798039734"
	},
	["diorite"] = {
		["icon"] = "rbxassetid://9072525407",
		["s"] = "rbxassetid://9072525496"
	},
	["diorite_polished"] = {
		["icon"] = "rbxassetid://9072553104",
		["s"] = "rbxassetid://9072553173"
	},
	["dirt"] = {
		["icon"] = "rbxassetid://7884368936",
		["s"] = "rbxassetid://7852097294"
	},
	["drawbridge"] = {
		["icon"] = "rbxassetid://12210620616",
		["s"] = "rbxassetid://12210620676"
	},
	["emerald_block"] = {
		["icon"] = "rbxassetid://7884369019",
		["s"] = "rbxassetid://7843773857"
	},
	["emerald_ore"] = {
		["icon"] = "rbxassetid://102665467637199",
		["s"] = "rbxassetid://137341028781546"
	},
	["fisherman_coral"] = {
		["icon"] = "rbxassetid://7884369108",
		["s"] = "rbxassetid://7843775572"
	},
	["food_lucky_block"] = {
		["d"] = "rbxassetid://14192272281",
		["icon"] = "rbxassetid://14192272584",
		["s"] = "rbxassetid://14192272698",
		["t"] = "rbxassetid://14192272804"
	},
	["forge_lucky_block"] = {
		["icon"] = "rbxassetid://15644713419",
		["s"] = "rbxassetid://15644713480",
		["td"] = "rbxassetid://15644713593"
	},
	["galactite"] = {
		["icon"] = "rbxassetid://15966082316",
		["s"] = "rbxassetid://15966093089"
	},
	["galactite_brick"] = {
		["icon"] = "rbxassetid://9839888714",
		["s"] = "rbxassetid://9839888790"
	},
	["glitched_lucky_block"] = {
		["icon"] = "rbxassetid://10866119664",
		["s"] = "rbxassetid://10849259593"
	},
	["glowstone"] = {
		["icon"] = "rbxassetid://12948863407",
		["s"] = "rbxassetid://12946930610"
	},
	["gold_block"] = {
		["icon"] = "rbxassetid://13465465532",
		["s"] = "rbxassetid://13456088345"
	},
	["granite"] = {
		["icon"] = "rbxassetid://9072553261",
		["s"] = "rbxassetid://9072525939"
	},
	["granite_polished"] = {
		["icon"] = "rbxassetid://9072553350",
		["s"] = "rbxassetid://9072553427"
	},
	["grass"] = {
		["d"] = "rbxassetid://7843778275",
		["icon"] = "rbxassetid://7911370722",
		["s"] = "rbxassetid://7911371120",
		["t"] = "rbxassetid://7911371279"
	},
	["guilded_iron"] = {
		["icon"] = "rbxassetid://10859696266",
		["s"] = "rbxassetid://10859696347"
	},
	["gum"] = {
		["icon"] = "rbxassetid://14549363304",
		["s"] = "rbxassetid://14549363342"
	},
	["halloween_lucky_block"] = {
		["icon"] = "rbxassetid://17367713630",
		["s"] = "rbxassetid://17367713680",
		["td"] = "rbxassetid://17367713724"
	},
	["haybale"] = {
		["icon"] = "rbxassetid://14968393791",
		["s"] = "rbxassetid://14969029405",
		["td"] = "rbxassetid://14969029474"
	},
	["hickory_log"] = {
		["icon"] = "rbxassetid://7884369330",
		["s"] = "rbxassetid://16991766362",
		["td"] = "rbxassetid://16991766405"
	},
	["ice"] = {
		["icon"] = "rbxassetid://7884369431",
		["s"] = "rbxassetid://16991766460"
	},
	["ice_frost_1"] = {
		["s"] = "rbxassetid://8221158413"
	},
	["ice_frost_2"] = {
		["s"] = "rbxassetid://8221571608"
	},
	["iron_block"] = {
		["icon"] = "rbxassetid://7884369517",
		["s"] = "rbxassetid://7852098030"
	},
	["iron_ore"] = {
		["icon"] = "rbxassetid://88425197437530",
		["s"] = "rbxassetid://98659207125198"
	},
	["kobblak"] = {
		["icon"] = "rbxassetid://9859002988",
		["s"] = "rbxassetid://9859003106",
		["td"] = "rbxassetid://9859003198"
	},
	["lantern"] = {
		["icon"] = "rbxassetid://12946930661",
		["s"] = "rbxassetid://12946930737"
	},
	["lantern_block"] = {
		["icon"] = "rbxassetid://12948863466",
		["s"] = "rbxassetid://12948863498"
	},
	["limestone"] = {
		["s"] = "rbxassetid://18880491571"
	},
	["log_maple"] = {
		["icon"] = "rbxassetid://7884369649",
		["s"] = "rbxassetid://16991766500",
		["td"] = "rbxassetid://16991766540"
	},
	["lucky_block"] = {
		["icon"] = "rbxassetid://7884369916",
		["s"] = "rbxassetid://7843804042"
	},
	["lucky_block_trap"] = {
		["icon"] = "rbxassetid://7884370012",
		["s"] = "rbxassetid://7843813175"
	},
	["magic_glass"] = {
		["icon"] = "rbxassetid://72863067929207",
		["s"] = "rbxassetid://121238080563616"
	},
	["magical_h_lucky_block"] = {
		["icon"] = "rbxassetid://16114558922",
		["s"] = "rbxassetid://16114558985"
	},
	["magical_hero_lucky_block"] = {
		["icon"] = "rbxassetid://16114559103",
		["s"] = "rbxassetid://16114559191"
	},
	["magical_v_lucky_block"] = {
		["icon"] = "rbxassetid://16114559288",
		["s"] = "rbxassetid://16114559343"
	},
	["magma_block"] = {
		["icon"] = "rbxassetid://9439108582",
		["s"] = "rbxassetid://9439108691"
	},
	["marble"] = {
		["icon"] = "rbxassetid://7884370119",
		["s"] = "rbxassetid://7861531930"
	},
	["marble_pillar"] = {
		["icon"] = "rbxassetid://7884370206",
		["s"] = "rbxassetid://16991766587",
		["td"] = "rbxassetid://16991766637"
	},
	["moss_block"] = {
		["icon"] = "rbxassetid://10866497548",
		["s"] = "rbxassetid://10866261237"
	},
	["new_years_lucky_block"] = {
		["icon"] = "rbxassetid://11958841642",
		["s"] = "rbxassetid://11958841720"
	},
	["new_years_lucky_block_2024"] = {
		["icon"] = "rbxassetid://15800004718",
		["s"] = "rbxassetid://15800004825"
	},
	["oak_log"] = {
		["icon"] = "rbxassetid://7884370279",
		["s"] = "rbxassetid://16991766678",
		["td"] = "rbxassetid://16991766755"
	},
	["obsidian"] = {
		["icon"] = "rbxassetid://8105569883",
		["s"] = "rbxassetid://16991766822"
	},
	["pumpkin"] = {
		["f"] = "rbxassetid://7843844110",
		["icon"] = "rbxassetid://7884370541",
		["s"] = "rbxassetid://7843844205",
		["td"] = "rbxassetid://7843849779"
	},
	["pumpkin_block"] = {
		["icon"] = "rbxassetid://14968393998",
		["s"] = "rbxassetid://14968394120",
		["td"] = "rbxassetid://14968394203"
	},
	["purple_lucky_block"] = {
		["icon"] = "rbxassetid://8105570365",
		["s"] = "rbxassetid://8105570571"
	},
	["rainbow_lucky_block"] = {
		["icon"] = "rbxassetid://12813794908",
		["s"] = "rbxassetid://12813795010"
	},
	["red_sand"] = {
		["icon"] = "rbxassetid://9072732616",
		["s"] = "rbxassetid://9072732694"
	},
	["red_sandstone"] = {
		["icon"] = "rbxassetid://7884370687",
		["s"] = "rbxassetid://7843853920"
	},
	["red_sandstone_polished"] = {
		["icon"] = "rbxassetid://10859696978",
		["s"] = "rbxassetid://10859697059"
	},
	["red_sandstone_smooth"] = {
		["icon"] = "rbxassetid://10859697143",
		["s"] = "rbxassetid://10859697202"
	},
	["sand"] = {
		["icon"] = "rbxassetid://7884370902",
		["s"] = "rbxassetid://7843856590"
	},
	["sandstone"] = {
		["icon"] = "rbxassetid://7884371048",
		["s"] = "rbxassetid://7872908360"
	},
	["sandstone_polished"] = {
		["icon"] = "rbxassetid://10859697278",
		["s"] = "rbxassetid://10859697352"
	},
	["sandstone_smooth"] = {
		["icon"] = "rbxassetid://10859697439",
		["s"] = "rbxassetid://10859697497"
	},
	["scaffold"] = {
		["icon"] = "rbxassetid://12210853999",
		["s"] = "rbxassetid://12210854096",
		["td"] = "rbxassetid://12211060975"
	},
	["siege_tnt"] = {
		["icon"] = "rbxassetid://14719641593",
		["s"] = "rbxassetid://14719641708",
		["td"] = "rbxassetid://14719641761"
	},
	["slate_brick"] = {
		["icon"] = "rbxassetid://9072553631",
		["s"] = "rbxassetid://9072526507"
	},
	["slate_tiles"] = {
		["icon"] = "rbxassetid://10859697544",
		["s"] = "rbxassetid://10859697603"
	},
	["slime_block"] = {
		["icon"] = "rbxassetid://7884371303",
		["s"] = "rbxassetid://16991766905"
	},
	["smoke_block"] = {
		["icon"] = "rbxassetid://8538034673",
		["s"] = "rbxassetid://8538034808"
	},
	["snow"] = {
		["icon"] = "rbxassetid://7884371442",
		["s"] = "rbxassetid://16991766975"
	},
	["spruce_log"] = {
		["icon"] = "rbxassetid://7884371618",
		["s"] = "rbxassetid://16991767062",
		["td"] = "rbxassetid://16991767140"
	},
	["steel_block"] = {
		["icon"] = "rbxassetid://10859697667",
		["s"] = "rbxassetid://10859697716"
	},
	["stone"] = {
		["icon"] = "rbxassetid://7884371892",
		["s"] = "rbxassetid://16991767248"
	},
	["stone_brick"] = {
		["icon"] = "rbxassetid://7884372079",
		["s"] = "rbxassetid://16991767326"
	},
	["stone_pillar"] = {
		["icon"] = "rbxassetid://10859697750",
		["s"] = "rbxassetid://10859697821",
		["td"] = "rbxassetid://12938322729"
	},
	["stone_slab"] = {
		["icon"] = "rbxassetid://8105570787",
		["s"] = "rbxassetid://8105570960"
	},
	["stone_tiles"] = {
		["icon"] = "rbxassetid://10859697942",
		["s"] = "rbxassetid://10859698016"
	},
	["testblock_magenta"] = {
		["s"] = "rbxassetid://12412674419"
	},
	["testblock_orange"] = {
		["s"] = "rbxassetid://12412674518"
	},
	["testblock_white"] = {
		["s"] = "rbxassetid://12412674601"
	},
	["tnt"] = {
		["icon"] = "rbxassetid://7884372237",
		["s"] = "rbxassetid://16991767398",
		["td"] = "rbxassetid://16991767491"
	},
	["void_block"] = {
		["icon"] = "rbxassetid://9871961934",
		["s"] = "rbxassetid://9871962545",
		["t"] = "rbxassetid://9871962653"
	},
	["void_dirt"] = {
		["s"] = "rbxassetid://15958116043"
	},
	["void_grass"] = {
		["d"] = "rbxassetid://15957915204",
		["s"] = "rbxassetid://15957915344",
		["t"] = "rbxassetid://15957915501"
	},
	["void_growth"] = {
		["s"] = "rbxassetid://15957915625"
	},
	["volatile_stone"] = {
		["icon"] = "rbxassetid://15380237898",
		["s"] = "rbxassetid://15380237968"
	},
	["wood_plank_birch"] = {
		["icon"] = "rbxassetid://7884372418",
		["s"] = "rbxassetid://16991767611"
	},
	["wood_plank_hickory"] = {
		["icon"] = "rbxassetid://7884372677",
		["s"] = "rbxassetid://16991767711"
	},
	["wood_plank_maple"] = {
		["icon"] = "rbxassetid://7884372787",
		["s"] = "rbxassetid://16991767778"
	},
	["wood_plank_oak"] = {
		["icon"] = "rbxassetid://7884372987",
		["s"] = "rbxassetid://16991767868"
	},
	["wood_plank_spruce"] = {
		["icon"] = "rbxassetid://7884373190",
		["s"] = "rbxassetid://16991767936"
	},
	["wool_black"] = {
		["icon"] = "rbxassetid://7923576966",
		["s"] = "rbxassetid://7861535149"
	},
	["wool_blue"] = {
		["icon"] = "rbxassetid://7923577182",
		["s"] = "rbxassetid://16991767991"
	},
	["wool_brown"] = {
		["icon"] = "rbxassetid://15380238075",
		["s"] = "rbxassetid://15380238175"
	},
	["wool_cyan"] = {
		["icon"] = "rbxassetid://7923577311",
		["s"] = "rbxassetid://16991768048"
	},
	["wool_dark_brown"] = {
		["icon"] = "rbxassetid://7923577434",
		["s"] = "rbxassetid://7861535961"
	},
	["wool_gray"] = {
		["icon"] = "rbxassetid://7923577537",
		["s"] = "rbxassetid://7861536309"
	},
	["wool_green"] = {
		["icon"] = "rbxassetid://7923577655",
		["s"] = "rbxassetid://16991768151"
	},
	["wool_light_brown"] = {
		["icon"] = "rbxassetid://7923577894",
		["s"] = "rbxassetid://7861537039"
	},
	["wool_light_green"] = {
		["icon"] = "rbxassetid://7923578022",
		["s"] = "rbxassetid://7923578149"
	},
	["wool_orange"] = {
		["icon"] = "rbxassetid://7923578297",
		["s"] = "rbxassetid://16991768271"
	},
	["wool_pink"] = {
		["icon"] = "rbxassetid://7923578533",
		["s"] = "rbxassetid://16991768418"
	},
	["wool_purple"] = {
		["icon"] = "rbxassetid://7923578762",
		["s"] = "rbxassetid://7923578873"
	},
	["wool_red"] = {
		["icon"] = "rbxassetid://7923579098",
		["s"] = "rbxassetid://16991768524"
	},
	["wool_white"] = {
		["icon"] = "rbxassetid://7923579263",
		["s"] = "rbxassetid://16991768606"
	},
	["wool_yellow"] = {
		["icon"] = "rbxassetid://7923579520",
		["s"] = "rbxassetid://16991768659"
	}
}
