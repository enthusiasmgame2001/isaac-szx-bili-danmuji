-- global variables
szxDanmuji = {}
szxDanmuji.danmuTable = {}

-- import the zzlib library
local zzlib = require("zzlib")
local json = require("json")

-- basic variables
local mod = RegisterMod("szx_bili_danmuji", 1)
local game = Game()
local font = Font()

--load font
local function loadFont()
	local _, err = pcall(require, "")
	local _, basePathStart = string.find(err, "no file '", 1)
	local _, modPathStart = string.find(err, "no file '", basePathStart)
	local modPathEnd, _ = string.find(err, ".lua", modPathStart)
	local path = string.sub(err, modPathStart + 1, modPathEnd - 1)
	path = string.gsub(path, "\\", "/")
	path = string.gsub(path, "//", "/")
	path = string.gsub(path, ":/", ":\\")
	font:Load(path .. "resources/font/cjk/lanapixel.fnt")
end
loadFont()

--load constants
local npcTable = require('./constants/npcTable')
local bossTable = require('./constants/bossTable')

-- text variables
local modVersion = "三只熊弹幕姬v2.2"
local inputBoxText = "请黏贴直播间号：[LCtrl + v]"
local instructionTextTable = {
    "按 [LCtrl + u] 重置登录账户",
    "按 [LCtrl + z] 重置直播间号",
    "按 [LCtrl + x] 开关弹幕姬",
    "按 [B] 打开设置菜单"
}

local getTokenPartUrl = "https://api.live.bilibili.com/xlive/web-room/v1/index/getDanmuInfo?id="
local getQRCodeUrl = "https://passport.bilibili.com/x/passport-login/web/qrcode/generate"
local getQRCodeScanResponsePartUrl = "https://passport.bilibili.com/x/passport-login/web/qrcode/poll?qrcode_key="
local getUserNameUrl = "https://api.live.bilibili.com/xlive/web-ucenter/user/get_user_info"
local danmuWsAddress = "wss://broadcastlv.chat.bilibili.com:443/sub"

local initHeader12 = "\x00\x00\x00\x2F\x00\x10\x00\x01\x00\x00\x00\x07"
local initUidKey = "\x7B\x22\x75\x69\x64\x22\x3A" -- {"uid":
local initUidValue = "" -- uid
local initRoomIdKey = "\x2C\x22\x72\x6F\x6F\x6D\x69\x64\x22\x3A" -- ,"roomid":
local initRoomIdValue = "" -- roomid
local initProtoVersion = "\x2C\x22\x70\x72\x6F\x74\x6F\x76\x65\x72\x22\x3A\x32" -- ,"protover":2
local initTokenKey = "\x2C\x22\x6B\x65\x79\x22\x3A" -- ,"key":
local initToken = initTokenKey

local heartHeader12 = "\x00\x00\x00\x13\x00\x10\x00\x01\x00\x00\x00\x02"
local heartText = "\x73\x7A\x78" -- szx

--state variables
local ws = nil
local danmujiOn = true
local sequence = 1
local timer = 0
local roomLatencyTimer = 0
local needAnimate = {}
local allTimerStop = false
local needClearFlag = nil
local needClearFlagEntityPickup = nil
local actEnemyTbl = {}

--danmu variables
local curDanmu = {"", "", ""}
local speechTimer = 0
local roomId = ""
local accessLevel = {
    BYOU = 0,
    FANS = 1,
    GUARD = 2,
    MANAGER = 3,
    AUTHOR = 4
}

--QR code variables
local spriteQRCodeTable = {}
local qRCodeSequence = {}
local qRCodeDimension = nil
local qRCodeStartPos = {200, 50}
local cookieStateTable = {
    INIT = 0, --初始状态，未启动getCookie过程
    START = 1, --开始getCookie过程
    WAIT_QRCODE_READY = 2, --等待生成二维码请求的响应
    QRCODE_READY = 3, --二维码已生成
    WAIT_SCAN_RESPONSE = 4, --等待获得二维码扫描情况的响应
    SUCCESS = 5, --扫码登录成功
    EXPIRED = 6, --二维码已失效
    TO_BE_CONFIRMED = 7, --用户已扫码，等待用户确认
    TO_BE_SCANNED = 8, --用户未代码，等待用户扫码
    COOKIE_IS_READY = 9, --Cookie已得到
    WAIT_USER_INFO_RESPONSE = 10, --等待获得用户信息的响应
    USER_INFO_RECEIVED = 11, --用户信息已得到
    END = 12 --ws对象创建完成
}
local cookieState = cookieStateTable.INIT
local qrCodeKey = ""
local userCookieUrl = ""
local qrRequestTimer = 0
local userName = ""
local cookieStr = ""

--config variables
local letPlayerControl = true
local canModifyConfig = false
local selectOption = 1
local selectedOption = 0
local optionQuestion = {
    "请选择需要修改的属性：(按[B]保存并退出设置)",
    "按[T]发送测试弹幕"
}
local optionList = {
    "弹幕文字大小",
    "弹幕持续时间",
    "生成指令互动",
    "友方怪物互动"
}
local configPosTable = {135, 55}
local configParameterTable = { -- {当前值, 最小值, 最大值, 步长, 单位名称, 显示系数}
    {10, 5, 50, 1, " 倍", 10},
    {20, 1, 120, 1, " 秒", 1},
    {0, 0, 1, 1, "", 1},
    {0, 0, 1, 1, "", 1}
}

local function simpleEncrypt(input)
    local output = input:gsub('[a-zA-Z0-9]', function(char)
        local encryptedChar = string.byte(char) + 1
        if char == 'z' then
            return 'a'
        elseif char == 'Z' then
            return 'A'
        elseif char == '9' then
            return '0'
        else
            return string.char(encryptedChar)
        end
    end)
    return output
end

local function simpleDecrypt(input)
    local output = input:gsub('[a-zA-Z0-9]', function(char)
        local decryptedChar = string.byte(char) - 1
        if char == 'a' then
            return 'z'
        elseif char == 'A' then
            return 'Z'
        elseif char == '0' then
            return '9'
        else
            return string.char(decryptedChar)
        end
    end)
    return output
end

local jsonTable = {}
if mod:HasData() then
    jsonTable = json.decode(mod:LoadData())
end
if jsonTable.cookie ~= nil and jsonTable.cookie ~= "" then
    cookieStr = simpleDecrypt(jsonTable.cookie) 
    cookieState = cookieStateTable.COOKIE_IS_READY
end
if jsonTable.textSize ~= nil then
    configParameterTable[1][1] = jsonTable.textSize
end
if jsonTable.textDuration ~= nil then
    configParameterTable[2][1] = jsonTable.textDuration
end

local function cloneTable(originalTable)
	local clone = {}
	for key, value in pairs(originalTable) do
		if type(value) == "table" then
			clone[key] = cloneTable(value)
		else
			clone[key] = value
		end
	end
	return clone
end

local itemOrderMap = cloneTable(require('./constants/itemOrderMap'))
local codeCommandMapTable = {
    ["c"] = {"spawn 5.100.", false},
    ["t"] = {"spawn 5.350.", false},
    ["T"] = {"spawn 5.350.", true},
    ["k"] = {"spawn 5.300.", false}
}

local function displayConfigMenu()
    if not game:IsPaused() then
        local frameChoose = false
        if selectedOption == 0 then
            if Input.IsActionTriggered(ButtonAction.ACTION_UP, 0) or Input.IsActionTriggered(ButtonAction.ACTION_SHOOTUP, 0) then
                selectOption = selectOption - 1
                if selectOption < 1 then
                    selectOption = #optionList
                end
            elseif Input.IsActionTriggered(ButtonAction.ACTION_DOWN, 0) or Input.IsActionTriggered(ButtonAction.ACTION_SHOOTDOWN, 0) then
                selectOption = selectOption + 1
                if selectOption > #optionList then
                    selectOption = 1
                end
            elseif Input.IsActionTriggered(ButtonAction.ACTION_ITEM, 0) or Input.IsButtonTriggered(Keyboard.KEY_ENTER, 0) or Input.IsActionTriggered(ButtonAction.ACTION_RIGHT, 0) or Input.IsActionTriggered(ButtonAction.ACTION_SHOOTRIGHT, 0) then
                selectedOption = selectOption
                frameChoose = true
            end
        end
        for i = 1, #optionList do
            if selectedOption == i then
                if i == 3 or i == 4 then
                    local isOnText = ""
                    if configParameterTable[i][1] > 0.5 then
                        isOnText = "开启"
                    else
                        isOnText = "关闭"
                    end
                    font:DrawStringUTF8(isOnText, configPosTable[1] + font:GetStringWidthUTF8(optionList[i] .. "    >>    "), configPosTable[2] + 18 * i, KColor(0.15, 0.7, 0.7, 1), 0, false)
                else
                    font:DrawStringUTF8(configParameterTable[i][1] / configParameterTable[i][6] .. configParameterTable[i][5], configPosTable[1] + font:GetStringWidthUTF8(optionList[i] .. "    >>    "), configPosTable[2] + 18 * i, KColor(0.15, 0.7, 0.7, 1), 0, false)
                end
                if Input.IsActionTriggered(ButtonAction.ACTION_UP, 0) or Input.IsActionTriggered(ButtonAction.ACTION_SHOOTUP, 0) then
                    if configParameterTable[i][1] < configParameterTable[i][3] then
                        configParameterTable[i][1] = configParameterTable[i][1] + configParameterTable[i][4]
                        if configParameterTable[i][1] > configParameterTable[i][3] then
                            configParameterTable[i][1] = configParameterTable[i][3]
                        end
                    end
                elseif Input.IsActionTriggered(ButtonAction.ACTION_DOWN, 0) or Input.IsActionTriggered(ButtonAction.ACTION_SHOOTDOWN, 0) then
                    if configParameterTable[i][1] > configParameterTable[i][2] then
                        configParameterTable[i][1] = configParameterTable[i][1] - configParameterTable[i][4]
                        if configParameterTable[i][1] < configParameterTable[i][2] then
                            configParameterTable[i][1] = configParameterTable[i][2]
                        end
                    end
                elseif Input.IsActionTriggered(ButtonAction.ACTION_ITEM, 0) or Input.IsButtonTriggered(Keyboard.KEY_ENTER, 0) or Input.IsActionTriggered(ButtonAction.ACTION_LEFT, 0) or Input.IsActionTriggered(ButtonAction.ACTION_SHOOTLEFT, 0) then
                    if not frameChoose then
                        selectedOption = 0
                    end
                end
                break
            end
        end
    end
    -- config option display
    font:DrawStringScaledUTF8(optionQuestion[1], configPosTable[1] - 15, configPosTable[2], 1, 1, KColor(0.8, 0.2, 0.5, 1), 0, false)
    font:DrawStringScaledUTF8(optionQuestion[2], configPosTable[1] + 150, configPosTable[2] + 9 * (#optionList + 1), 1, 1, KColor(0.8, 0.2, 0.5, 1), 0, false)
    for i = 1, #optionList do
        if selectOption == i then
            font:DrawStringUTF8(optionList[i] .. "    >>", configPosTable[1], configPosTable[2] + 18 * i, KColor(0.15, 0.7, 0.7, 1), 0, false)
        else
            font:DrawStringUTF8(optionList[i] .. "    >>", configPosTable[1], configPosTable[2] + 18 * i, KColor(0.075, 0.35, 0.35, 1), 0, false)
        end
    end
end

local function elementInList(n, targetList)
    for _, v in ipairs(targetList) do
        if n == v then
            return true
        end
    end
    return false
end

local function executeAnimation(n)
	local playerNum = game:GetNumPlayers()
	for i = 0, playerNum - 1 do
		local player = Isaac.GetPlayer(i)
		if n == 1 then
			player:AnimateHappy()
		elseif n == 2 then
			player:AnimateSad()
		end
	end
end

local function displayTitle()
    font:DrawStringUTF8(modVersion, 275, 183, KColor(1, 1, 1, 1), 0, false)
    font:DrawStringUTF8(inputBoxText, 275, 223, KColor(1, 1, 1, 1), 0, false)
    for i = 1, #instructionTextTable do
        font:DrawStringUTF8(instructionTextTable[i], 60, 163 + 20 * i, KColor(1, 0.75, 0, 1), 0, false)
    end
    font:DrawStringUTF8("当前登录用户：" .. userName, 275, 203, KColor(1, 1, 1, 1), 0, false)
end

local function initQRCodeSequence(qrCodeUrl)
    local qrencode = require("qrencode.lua")
    local ok, tab_or_message = qrencode.qrcode(qrCodeUrl)
    qRCodeDimension = #tab_or_message
    if not ok then
        curDanmu[1] = ""
        curDanmu[2] = ""
        curDanmu[3] = {"二维码图像生成失败：" .. tab_or_message, 1}
        speechTimer = 150
    end

    spriteQRCodeTable = {}
    for i = 1, qRCodeDimension*qRCodeDimension do
        spriteQRCodeTable[i] = Sprite()
        spriteQRCodeTable[i]:Load("gfx/qrcode.anm2", true)
        spriteQRCodeTable[i].Scale = Vector(2, 2)
    end
    qRCodeSequence = {}
    for i = 1, qRCodeDimension do
        for j = 1, qRCodeDimension do
            table.insert(qRCodeSequence, tab_or_message[i][j])
        end
    end
end

local function diplayQRCode()
    for idx, sprite in ipairs(spriteQRCodeTable) do
        sprite:Play("Keys")
        if qRCodeSequence[idx] >= 0 then
            sprite:SetLayerFrame(0, 0)
        else
            sprite:SetLayerFrame(0, 1)
        end
        local posX = qRCodeStartPos[1] + ((idx - 1) % qRCodeDimension) * 2
        local posY = qRCodeStartPos[2] + ((idx - 1) // qRCodeDimension) * 2
        sprite:Render(Vector(posX, posY), Vector.Zero, Vector.Zero)
    end
end

local function getCurDanmu(message)
    local p = 1
    while p + 15 <= #message do
        local packetLength, headerLength, protoVersion, packetType, _, offset = string.unpack(">I4I2I2I4I4", message, p)
        local text = string.sub(message, p + 16, p + packetLength - 1)
        if protoVersion == 2 then
            getCurDanmu(zzlib.inflate(text))
        elseif packetType == 3 then
            -- 人气值
        elseif packetType == 5 then
            local messageTable = json.decode(text)
            local commandType = messageTable.cmd
            local commandType = messageTable.cmd
            if commandType:sub(1, 9) == "DANMU_MSG" then --弹幕
                if messageTable.info[1][10] ~= 2 then --排除抽奖弹幕
                    curDanmu[1] = messageTable.info[2]
                    curDanmu[2] = messageTable.info[3][2]
                    curDanmu[3] = ""
                    speechTimer = configParameterTable[2][1] * 30
                    local curAccessLevel = accessLevel.BYOU
                    if messageTable.info[4][4] ~= nil and tostring(messageTable.info[4][4]) == roomId then
                        curAccessLevel = accessLevel.FANS
                    end
                    if messageTable.info[8] ~= 0 then
                        curAccessLevel = accessLevel.GUARD
                    end
                    if messageTable.info[3][3] == 1 then
                        curAccessLevel = accessLevel.MANAGER
                    end
                    if curDanmu[2] == "enthusiasmgame" then
                        curAccessLevel = accessLevel.AUTHOR
                    end
                    table.insert(szxDanmuji.danmuTable, {curDanmu[1], curDanmu[2], curAccessLevel})
                end
            elseif commandType == "POPULARITY_RED_POCKET_NEW" then --留言红包
                local data = messageTable.data
                curDanmu[1] = "送出了1个红包[" .. data.price .. "金电池]"
                curDanmu[2] = data.uname
                curDanmu[3] = ""
                speechTimer = configParameterTable[2][1] * 30
            elseif commandType == "GUARD_BUY" then --上舰
                local data = messageTable.data
                local guardNameTable = {"总督", "提督", "舰长"}
                curDanmu[1] = "开通了" .. data.num .. "个月" .. guardNameTable[data.guard_level]
                curDanmu[2] = messageTable.data.username
                curDanmu[3] = ""
                speechTimer = configParameterTable[2][1] * 30
            elseif commandType == "SUPER_CHAT_MESSAGE" then --醒目留言
                local data = messageTable.data
                curDanmu[1] = data.message .. "[醒目留言:" .. data.price .. "元]"
                curDanmu[2] = data.user_info.uname
                curDanmu[3] = ""
                speechTimer = configParameterTable[2][1] * 30
            elseif commandType == "SEND_GIFT" then --送礼
                local data = messageTable.data
                local coinTypeTable = {["gold"] = {"金电池", 0.01} , ["silver"] = {"银瓜子", 1}}
                local realPrice = data.price * coinTypeTable[data.coin_type][2]
                local t1, t2 = math.modf(realPrice)
                if t2 == 0 then
                    realPrice = t1
                end
                curDanmu[1] = "送出了1个" .. data.giftName .. "[" .. realPrice .. coinTypeTable[data.coin_type][1] .. "]"
                curDanmu[2] = data.uname
                curDanmu[3] = ""
                speechTimer = configParameterTable[2][1] * 30
            end
        elseif packetType == 8 then
            -- 认证成功
        else
            -- 未知操作
        end
        p = p + packetLength
    end
end

local function getSequenceBytes(seq)
    local seqBytes = string.char((seq >> 24) & 0xFF, (seq >> 16) & 0xFF, (seq >> 8) & 0xFF, seq & 0xFF)

    return seqBytes
end

local function sendInitPacket()
    local headerSequenceBytes = getSequenceBytes(sequence)
    local header = initHeader12:sub(1, 3) .. string.char(46 + #initUidValue + #initRoomIdValue + #initToken) .. initHeader12:sub(5) .. headerSequenceBytes
    local packet = header .. initUidKey .. initUidValue .. initRoomIdKey .. initRoomIdValue .. initProtoVersion .. initToken
    ws.Send(packet, true)
    curDanmu[1] = ""
    curDanmu[2] = ""
    curDanmu[3] = {"已成功连接 " .. roomId .. " 直播间", 2}
    local saveDataTable = {}
    saveDataTable.roomId = roomId
    saveDataTable.cookie = simpleEncrypt(cookieStr)
    saveDataTable.textSize = configParameterTable[1][1]
    saveDataTable.textDuration = configParameterTable[2][1]
    mod:SaveData(json.encode(saveDataTable))
end

local function sendHeartBeatPacket()
    local headerSequenceBytes = getSequenceBytes(sequence)
    local header = heartHeader12 .. headerSequenceBytes
    local packet = header .. heartText
    if ws.IsOpen() then
        ws.Send(packet, true)
    else
        curDanmu[1] = ""
        curDanmu[2] = ""
        curDanmu[3] = {"心跳包发送失败", 1}
        speechTimer = 150
    end
end

local function closeWebSocket()
    if IsaacSocket ~= nil then
        ws.Close(1000, "Normal Closure")
        curDanmu[1] = ""
        curDanmu[2] = ""
        curDanmu[3] = {"正在断开连接", 2}
    else
        curDanmu[1] = ""
        curDanmu[2] = ""
        curDanmu[3] = {"IsaacSocket未正常工作(断开连接)", 1}
    end
end

local function CallbackOnOpen()
    if IsaacSocket ~= nil then
        if ws ~= nil then
            sendInitPacket()
            sequence = sequence + 1
        else
            curDanmu[1] = ""
            curDanmu[2] = ""
            curDanmu[3] = {"websocket对象为空(请把这条消息告诉作者谢谢)", 3}
        end
    else
        curDanmu[1] = ""
        curDanmu[2] = ""
        curDanmu[3] = {"IsaacSocket未正常工作(发送认证包)", 1}
    end
    speechTimer = 150
end

local function CallbackOnMessage(message, isBinary)
    if isBinary then
        getCurDanmu(message)
    else
        curDanmu[1] = "服务器文本消息：" .. message
        curDanmu[2] = "请把这条消息告诉作者谢谢"
        curDanmu[3] = ""
        speechTimer = 600
    end
end

local function CallbackOnClose(closeStatus, message)
    local closeTextTable = {}
    if closeStatus == 1000 then
        closeTextTable = {"断开连接成功", 2}
    else
        closeTextTable = {"自动断开连接", 1}
    end
    curDanmu[1] = message
    curDanmu[2] = ""
    curDanmu[3] = {closeTextTable[1] .. "[" .. closeStatus .. "]", closeTextTable[2]}
    speechTimer = 150
end

local function CallbackOnError(message)
    curDanmu[1] = ""
    curDanmu[2] = ""
    curDanmu[3] = {"连接出现错误:" .. message, 1}
    speechTimer = 150
end

local function updateItemTables()
	local itemConfig = Isaac.GetItemConfig()
	local insertIndexCollectible = 0
	local insertIndexTrinket = 0
	local insertIndexCard = 0
	for j, item in ipairs(itemOrderMap) do
		if item == "c732" then
			insertIndexCollectible = j + 1
			break
		end
	end
	for i = 1, 3 do
		local startEndNumTable = {{10000, 733}, {2000, 190}, {1000, 98}}
		for itemIndex = startEndNumTable[i][1], startEndNumTable[i][2], -1 do
			local item = nil
			if i == 1 then
				item = itemConfig:GetCollectible(itemIndex)
			elseif i == 2 then
				item = itemConfig:GetTrinket(itemIndex)
			elseif i == 3 then
				item = itemConfig:GetCard(itemIndex)
			end
			if item ~= nil then
				local id = item.ID
				local code = ""
				if i == 1 then
					code = "c" .. id
				elseif i == 2 then
					code = "t" .. id
				elseif i == 3 then
					code = "k" .. id
				end
				if i == 1 then
					table.insert(itemOrderMap, insertIndexCollectible, code)
				elseif i == 2 then
					table.insert(itemOrderMap, insertIndexTrinket, code)
				elseif i == 3 then
					table.insert(itemOrderMap, insertIndexCard, code)
				end
			end
		end
		if i == 1 then
			for j, item in ipairs(itemOrderMap) do
				if item  == "t189" then
					insertIndexTrinket = j + 1
					break
				end
			end
		elseif i == 2 then
			for j, item in ipairs(itemOrderMap) do
				if item  == "k97" then
					insertIndexCard = j + 1
					break
				end
			end
		end
	end
end

local function executeDanmuCommand(tbl)
    --manager access
    if tbl[3] >= accessLevel.MANAGER then
        if tbl[1] == "清理怪物" then
            for _, entity in pairs(Isaac.GetRoomEntities()) do
                local name = entity:GetData().name
                if name ~= nil and name ~= "enthusiasmgame" then
                    entity:Remove()
                end
            end
        end
        if tbl[3] == accessLevel.AUTHOR then
            if tbl[1] == "清理所有怪物" then
                for _, entity in pairs(Isaac.GetRoomEntities()) do
                    local name = entity:GetData().name
                    if name ~= nil then
                        entity:Remove()
                    end
                end
            elseif tbl[1] == "清理我的怪物" then
                for _, entity in pairs(Isaac.GetRoomEntities()) do
                    local name = entity:GetData().name
                    if name ~= nil and name == "enthusiasmgame" then
                        entity:Remove()
                    end
                end
            elseif tbl[1] == "r *" then
                Isaac.ExecuteCommand("r *")
            end
        end
    end
    --guard access
    if tbl[3] >= accessLevel.GUARD then
        if tbl[1] == "化友为敌" then
            for _, entity in pairs(Isaac.GetRoomEntities()) do
                local name = entity:GetData().name
                if name ~= nil and name == tbl[2] then
                    entity:GetData().color = {0.8, 0.1, 0.1}
                    entity:ClearEntityFlags(EntityFlag.FLAG_FRIENDLY | EntityFlag.FLAG_CHARM)
                end
            end
        elseif tbl[1] == "化敌为友" then
            for _, entity in pairs(Isaac.GetRoomEntities()) do
                local name = entity:GetData().name
                if name ~= nil and name == tbl[2] then
                    entity:GetData().color = {0.1, 0.8, 0.1}
                    entity:AddEntityFlags(EntityFlag.FLAG_FRIENDLY | EntityFlag.FLAG_PERSISTENT | EntityFlag.FLAG_CHARM)
                end
            end
        end
    end
    --fans access
    if configParameterTable[4][1] > 0.5 then
        if tbl[3] >= accessLevel.FANS then
            if tbl[1] == "生成随机友方怪物" then
                local nameExist = false
                if tbl[3] ~= accessLevel.AUTHOR then
                    for _, entity in pairs(Isaac.GetRoomEntities()) do
                        if entity:GetData().name == tbl[2] then
                            nameExist = true
                            break
                        end
                    end
                end
                if not nameExist then
                    local targetTable = npcTable
                    if Random() % 4 == 0 then
                        targetTable = bossTable
                    end
                    local spawnEnemyTbl = {}
                    local a = 1 + Random() % #targetTable
                    local b = 1 + Random() % #targetTable[a]
                    local codeStr = targetTable[a][b]
                    for part in codeStr:gmatch("[^%.]+") do
                        table.insert(spawnEnemyTbl, tonumber(part))
                    end
                    table.insert(spawnEnemyTbl, tbl[2])
                    table.insert(actEnemyTbl, spawnEnemyTbl)
                    Isaac.ExecuteCommand("spawn " .. codeStr)
                end
                return
            end
        end
    end
    if configParameterTable[3][1] > 0.5 then
        if tbl[3] >= accessLevel.FANS then
            if #tbl[1] > 7 then
                if tbl[1]:sub(1, 6) == "生成" then
                    local code = tbl[1]:sub(7)
                    if elementInList(code:lower(), itemOrderMap) then
                        local prefix = code:sub(1, 1)
                        local subType = code:sub(2)
                        if codeCommandMapTable[prefix] ~= nil then
                            if codeCommandMapTable[prefix][2] then
                                subType = subType + 32768
                            end
                            local curCommand = codeCommandMapTable[prefix][1] .. subType
                            needClearFlag = true
                            Isaac.ExecuteCommand(curCommand)
                            needClearFlag = nil
                            if needClearFlagEntityPickup then
                                needClearFlagEntityPickup:ClearEntityFlags(EntityFlag.FLAG_ITEM_SHOULD_DUPLICATE)
                                needClearFlagEntityPickup = nil
                            end
                        end
                    end
                end
            end
        end
    end
end

local function updateCookieState()
    if cookieState == cookieStateTable.INIT then
        if cookieStr == "" then
            cookieState = cookieStateTable.START
        else
            cookieState = cookieStateTable.COOKIE_IS_READY
        end
    elseif cookieState == cookieStateTable.START or cookieState == cookieStateTable.EXPIRED then
        allTimerStop = true
        cookieState = cookieStateTable.WAIT_QRCODE_READY
        local url = getQRCodeUrl
        local headers = {}
        IsaacSocket.HttpClient.GetAsync(url, headers).Then(function(task)
            if task.IsCompletedSuccessfully() then
                local response = task.GetResult()
                local body = json.decode(response.body)
                if body.code == 0 then
                    initQRCodeSequence(body.data.url)
                    qrCodeKey = body.data.qrcode_key
                    cookieState = cookieStateTable.QRCODE_READY
                    curDanmu[1] = ""
                    curDanmu[2] = ""
                    curDanmu[3] = {"请扫码(手动重置二维码请按[LCtrl+u])", 2}
                else
                    curDanmu[1] = ""
                    curDanmu[2] = ""
                    curDanmu[3] = {"二维码获得失败,code="..body.code, 1}
                    cookieState = cookieStateTable.START
                end
            else
                curDanmu[1] = ""
                curDanmu[2] = ""
                curDanmu[3] = {"二维码获得失败,错误信息："..task.GetResult(), 1}
                cookieState = cookieStateTable.START
            end
            speechTimer = 150
        end)
    elseif cookieState == cookieStateTable.QRCODE_READY or cookieState == cookieStateTable.TO_BE_SCANNED or cookieState == cookieStateTable.TO_BE_CONFIRMED then
        cookieState = cookieStateTable.WAIT_SCAN_RESPONSE
        local url = getQRCodeScanResponsePartUrl .. qrCodeKey
        local headers = {}
        IsaacSocket.HttpClient.GetAsync(url, headers).Then(function(task)
            if task.IsCompletedSuccessfully() then
                local response = task.GetResult()
                local body = json.decode(response.body)
                if body.code == 0 then
                    local responseCode = body.data.code
                    if responseCode == 0 then
                        qrCodeKey = ""
                        userCookieUrl = body.data.url
                        cookieState = cookieStateTable.SUCCESS
                        curDanmu[1] = ""
                        curDanmu[2] = ""
                        curDanmu[3] = {"登录成功", 2}
                    elseif responseCode == 86038 then
                        qrCodeKey = ""
                        cookieState = cookieStateTable.EXPIRED
                    elseif responseCode == 86090 then
                        cookieState = cookieStateTable.TO_BE_CONFIRMED
                    elseif responseCode == 86101 then
                        cookieState = cookieStateTable.TO_BE_SCANNED
                    end
                else
                    curDanmu[1] = ""
                    curDanmu[2] = ""
                    curDanmu[3] = {"检测扫描结果失败,code="..body.code, 1}
                end
            else
                curDanmu[1] = ""
                curDanmu[2] = ""
                curDanmu[3] = {"检测扫描结果失败,错误信息："..task.GetResult(), 1}
            end
            speechTimer = 150
        end)
    elseif cookieState == cookieStateTable.SUCCESS then
        local paramsPart = string.sub(userCookieUrl, string.find(userCookieUrl, "?") + 1)

        local keyValuePairs = {}
        for pair in paramsPart:gmatch("([^&]+)") do
            local key, value = pair:match("([^=]+)=([^=]+)")
            keyValuePairs[key] = value
        end

        local targetParameters = {"DedeUserID", "DedeUserID__ckMd5", "SESSDATA", "bili_jct"}
        local extractedParams = {}
        local cookieMissing = false
        for _, paramName in ipairs(targetParameters) do
            local value = keyValuePairs[paramName]
            if value then
                extractedParams[paramName] = value
            else
                cookieMissing = true
                curDanmu[1] = ""
                curDanmu[2] = ""
                curDanmu[3] = {"cookie字段缺失：".. paramName, 1}
            end
        end
        if cookieMissing then
            cookieState = cookieStateTable.START
            speechTimer = 150
        else
            for paramName, value in pairs(extractedParams) do
                if cookieStr ~= "" then
                    cookieStr = cookieStr .. "; "
                end
                cookieStr = cookieStr .. paramName .. "=" .. value
            end
            cookieState = cookieStateTable.COOKIE_IS_READY
            local saveDataTable = {}
            saveDataTable.roomId = roomId
            saveDataTable.cookie = simpleEncrypt(cookieStr)
            saveDataTable.textSize = configParameterTable[1][1]
            saveDataTable.textDuration = configParameterTable[2][1]
            mod:SaveData(json.encode(saveDataTable))
        end
    elseif cookieState == cookieStateTable.COOKIE_IS_READY then
        cookieState = cookieStateTable.WAIT_USER_INFO_RESPONSE
        local url = getUserNameUrl
        local headers = {
            ["Cookie"] = cookieStr
        }
        IsaacSocket.HttpClient.GetAsync(url, headers).Then(function(task)
            if task.IsCompletedSuccessfully() then
                local response = task.GetResult()
                local body = json.decode(response.body)
                if body.code == 0 then
                    userName = body.data.uname
                    initUidValue = tostring(body.data.uid)
                    cookieState = cookieStateTable.USER_INFO_RECEIVED
                else
                    curDanmu[1] = ""
                    curDanmu[2] = ""
                    curDanmu[3] = {"获得用户信息失败,code="..body.code, 1}
                end
            else
                curDanmu[1] = ""
                curDanmu[2] = ""
                curDanmu[3] = {"获得用户信息失败,错误信息："..task.GetResult(), 1}
            end
            speechTimer = 150
        end)
    end
end

local function getTokenAndCreateWebSocketObject(useClipboard)
    if ws == nil then     
        if IsaacSocket ~= nil then
            if useClipboard then
                local pasteText = IsaacSocket.System.GetClipboard()
                if pasteText == nil or #pasteText == 0 then
                    curDanmu[1] = ""
                    curDanmu[2] = ""
                    curDanmu[3] = {"剪贴板为空或非纯文本", 1}
                    speechTimer = 150
                    return
                else
                    local isLegal = true
                    for i = 1, #pasteText do
                        local char = pasteText:sub(i, i)
                        local num = tonumber(char)
                        if num == nil then
                            isLegal = false
                            break
                        else
                            if math.floor(num) ~= num or num < 0 or num > 9 then
                                isLegal = false
                                break
                            end
                        end
                    end
                    if isLegal then
                        initRoomIdValue = pasteText
                        roomId = pasteText
                        curDanmu[1] = ""
                        curDanmu[2] = ""
                        curDanmu[3] = {"正在初始化连接", 2}
                        speechTimer = 150
                    else
                        curDanmu[1] = ""
                        curDanmu[2] = ""
                        curDanmu[3] = {"剪贴板非纯数字", 1}
                        speechTimer = 150
                        return
                    end
                end
            else
                if initRoomIdValue ~= roomId then
                    initRoomIdValue = roomId
                    curDanmu[1] = ""
                    curDanmu[2] = ""
                    curDanmu[3] = {"正在初始化连接", 2}
                    speechTimer = 150
                end
            end
            inputBoxText = "正在连接直播间：" .. initRoomIdValue
            if qrRequestTimer == 15 then
                updateCookieState()
            end
            if cookieState == cookieStateTable.USER_INFO_RECEIVED then
                local url = getTokenPartUrl .. roomId
                local headers = {
                    ["Cookie"] = cookieStr
                }
                IsaacSocket.HttpClient.GetAsync(url, headers).Then(function(task)
                    if task.IsCompletedSuccessfully() then
                        local response = task.GetResult()
                        local body = json.decode(response.body)
                        if body.code == 0 then
                            initToken = initTokenKey .. '"' .. body.data.token .. '"' .. "\x7D"
                            ws = IsaacSocket.WebSocketClient.New(danmuWsAddress, CallbackOnOpen, CallbackOnMessage, CallbackOnClose, CallbackOnError)
                        else
                            curDanmu[1] = ""
                            curDanmu[2] = ""
                            curDanmu[3] = {"token获得失败,code="..body.code, 1}
                        end
                    else
                        curDanmu[1] = ""
                        curDanmu[2] = ""
                        curDanmu[3] = {"token获得失败,错误信息："..task.GetResult(), 1}
                    end
                    speechTimer = 150
                    allTimerStop = false
                end)
                cookieState = cookieStateTable.END
            end
        else
            curDanmu[1] = ""
            curDanmu[2] = ""
            curDanmu[3] = {"IsaacSocket未正常工作(连接直播间)", 1}
            speechTimer = 150
        end
    end
end

local function updatePlayerControlState(letControl)
	local playerNum = game:GetNumPlayers()
	for i = 0, playerNum - 1 do
		local player = Isaac.GetPlayer(i)
		if not letControl then
			player.ControlsCooldown = 2
		end
	end
end

local function onPostNpcInit(_, entityNpc)
    local type = entityNpc.Type
    local variant = entityNpc.Variant
    local subType = entityNpc.SubType
    if entityNpc.SpawnerEntity ~= nil then
        local data = entityNpc.SpawnerEntity:GetData()
        if data.name ~= nil then
            entityNpc:GetData().name = data.name
            entityNpc:GetData().index = data.index + 1
            entityNpc:GetData().color = data.color
            return
        end
    end
    local index = nil
    for i, tbl in ipairs(actEnemyTbl) do
        if type == tbl[1] and variant == tbl[2] then
            local data = entityNpc:GetData()
            data.name = tbl[4]
            data.index = 1
            data.color = {0.1, 0.8, 0.1}
            entityNpc:AddEntityFlags(EntityFlag.FLAG_FRIENDLY | EntityFlag.FLAG_PERSISTENT | EntityFlag.FLAG_CHARM)
            index = i
            break
        end
    end
    if index ~= nil then
        table.remove(actEnemyTbl, index)
    end
end

local function onPostPickupInit(_, entityPickup)
    if needClearFlag then
        needClearFlagEntityPickup = entityPickup
    end
end

local function onGameStart(_, IsContinued)
    if not IsContinued then
        configParameterTable[3][1] = 0
        configParameterTable[4][1] = 0
    end
    canModifyConfig = false
    letPlayerControl = true
    allTimerStop = false
    needAnimate = {false, false}
    szxDanmuji.danmuTable = {}
    updateItemTables()
end

local function onUpdate()
    updatePlayerControlState(letPlayerControl)
    if not allTimerStop and speechTimer > 0 then
        speechTimer = speechTimer - 1
    end
    if #szxDanmuji.danmuTable > 0 then
        while #szxDanmuji.danmuTable ~= 0 do
            executeDanmuCommand(szxDanmuji.danmuTable[1])
            table.remove(szxDanmuji.danmuTable, 1)
        end
    end
    --animate happy or sad
	for i = 1, #needAnimate do
		if needAnimate[i] then
			executeAnimation(i)
			needAnimate[i] = false
		end
	end
end

local function onRender(_)
    local isCtrlPressed = Input.IsButtonPressed(Keyboard.KEY_LEFT_CONTROL, 0)
    if Input.IsButtonTriggered(Keyboard.KEY_B, 0) then
        letPlayerControl = canModifyConfig
        canModifyConfig = not canModifyConfig
        selectedOption = 0
        selectOption = 1
        if not canModifyConfig then
            local saveDataTable = {}
            saveDataTable.roomId = roomId
            saveDataTable.cookie = simpleEncrypt(cookieStr)
            saveDataTable.textSize = configParameterTable[1][1]
            saveDataTable.textDuration = configParameterTable[2][1]
            mod:SaveData(json.encode(saveDataTable))
        end
    end
    if canModifyConfig then
        displayConfigMenu()
        if Input.IsButtonTriggered(Keyboard.KEY_T, 0) then
            curDanmu[1] = "这是一条测试弹幕"
            curDanmu[2] = "用户名123"
            curDanmu[3] = ""
            speechTimer = configParameterTable[2][1] * 30
        end
    end
    if isCtrlPressed and Input.IsButtonTriggered(Keyboard.KEY_U, 0) then
        if danmujiOn then
            cookieState = cookieStateTable.START
            cookieStr = ""
            curDanmu[1] = ""
            curDanmu[2] = ""
            curDanmu[3] = {"二维码登录已重置", 2}
            speechTimer = 150
            local saveDataTable = {}
            if roomId ~= "" then
                saveDataTable.roomId = roomId
            end
            saveDataTable.textSize = configParameterTable[1][1]
            saveDataTable.textDuration = configParameterTable[2][1]
            mod:SaveData(json.encode(saveDataTable))
        end
        if ws ~= nil then
            closeWebSocket()
        end
        ws = nil
        timer = 0
        sequence = 1
        roomLatencyTimer = 0
        allTimerStop = false
        userName = ""
    end
    if isCtrlPressed and Input.IsButtonTriggered(Keyboard.KEY_X, 0) then
        if ws ~= nil then
            closeWebSocket()
            speechTimer = 150
        else
            speechTimer = 0
        end
        ws = nil
        timer = 0
        sequence = 1
        roomLatencyTimer = 0
        roomId = ""
        allTimerStop = false
        inputBoxText = "请黏贴直播间号：[LCtrl + v]"
        danmujiOn = not danmujiOn
        if danmujiOn then
            cookieState = cookieStateTable.INIT
        else
            cookieState = cookieStateTable.END
        end
    end
    if isCtrlPressed and Input.IsButtonTriggered(Keyboard.KEY_Z, 0) then
        if ws ~= nil then
            closeWebSocket()
            speechTimer = 150
        else
            speechTimer = 0
        end
        ws = nil
        timer = 0
        sequence = 1
        roomLatencyTimer = 0
        roomId = ""
        allTimerStop = false
        inputBoxText = "请黏贴直播间号：[LCtrl + v]"
        local saveDataTable = {}
        saveDataTable.cookie = simpleEncrypt(cookieStr)
        saveDataTable.textSize = configParameterTable[1][1]
        saveDataTable.textDuration = configParameterTable[2][1]
        mod:SaveData(json.encode(saveDataTable))
        danmujiOn = true
        cookieState = cookieStateTable.INIT
    end
    if danmujiOn and (ws == nil or roomLatencyTimer < 300) then
        displayTitle()
        if roomId == "" then
            local jsonTable = {}
            if mod:HasData() then
                jsonTable = json.decode(mod:LoadData())
            end
            if jsonTable.roomId ~= nil and jsonTable.roomId ~= "" then
                roomId = jsonTable.roomId
            end
        end
        if roomId ~= "" then
            getTokenAndCreateWebSocketObject(false)
        else
            if isCtrlPressed and Input.IsButtonTriggered(Keyboard.KEY_V, 0) then
                getTokenAndCreateWebSocketObject(true)
            end 
        end
    end
    if ws ~= nil and not allTimerStop then
        if roomLatencyTimer < 300 then
            roomLatencyTimer = roomLatencyTimer + 1
        end
        timer = timer + 1
    end
    if timer >= 1800 then
        timer = 0
    end
    qrRequestTimer = qrRequestTimer + 1
    if qrRequestTimer >= 120 then
        qrRequestTimer = 0
    end
    if timer == 900 then
        if IsaacSocket ~= nil then
            if ws ~= nil then
                sendHeartBeatPacket()
                sequence = sequence + 1
            else
                curDanmu[1] = ""
                curDanmu[2] = ""
                curDanmu[3] = {"websocket对象为空(请把这条消息告诉作者谢谢)", 1}
                speechTimer = 150
            end
        else
            curDanmu[1] = ""
            curDanmu[2] = ""
            curDanmu[3] = {"IsaacSocket未正常工作(发送心跳包)", 1}
            speechTimer = 150
        end
    end
    local room = game:GetRoom()
	local isMirrored = room:IsMirrorWorld()
	local screenWidth = Isaac.GetScreenWidth()
    --render danmu and danmu names on player
    if speechTimer > 0 then
        local player = Isaac.GetPlayer(0)
        local pos = Isaac.WorldToScreen(player.Position)
        if isMirrored then
            pos.X = screenWidth - pos.X
        end
        local scaleCoef = configParameterTable[1][1] / configParameterTable[1][6]
        if curDanmu[1] ~= "" then 
            font:DrawStringScaledUTF8(curDanmu[1], pos.X - scaleCoef * font:GetStringWidthUTF8(curDanmu[1]) / 2, pos.Y - 36 * player.SpriteScale.Y - 8 - scaleCoef * font:GetLineHeight(), scaleCoef, scaleCoef, KColor(1, 1, 1, 1), 0, false)
        end
        if curDanmu[2] ~= "" then
            font:DrawStringScaledUTF8(curDanmu[2], pos.X - scaleCoef * font:GetStringWidthUTF8(curDanmu[2]) / 2, pos.Y + 4 * player.SpriteScale.Y, scaleCoef, scaleCoef, KColor(1, 0.75, 0, 1), 0, false)
        end
        if curDanmu[3] ~= "" then
            if curDanmu[3][2] == 1 then
                font:DrawStringScaledUTF8(curDanmu[3][1], pos.X - scaleCoef * font:GetStringWidthUTF8(curDanmu[3][1]) / 2, pos.Y + 4 * player.SpriteScale.Y, scaleCoef, scaleCoef, KColor(0.8, 0.1, 0.1, 1), 0, false)
            elseif curDanmu[3][2] == 2 then
                font:DrawStringScaledUTF8(curDanmu[3][1], pos.X - scaleCoef * font:GetStringWidthUTF8(curDanmu[3][1]) / 2, pos.Y + 4 * player.SpriteScale.Y, scaleCoef, scaleCoef, KColor(0.1, 0.8, 0.1, 1), 0, false)
            elseif curDanmu[3][2] == 3 then
                font:DrawStringScaledUTF8(curDanmu[3][1], pos.X - scaleCoef * font:GetStringWidthUTF8(curDanmu[3][1]) / 2, pos.Y + 4 * player.SpriteScale.Y, scaleCoef, scaleCoef, KColor(1, 0.75, 0, 1), 0, false)
            end
        end
    end
    --render danmu names on npc
    local allNameNpcTbl = {}
    for _, entity in pairs(Isaac.GetRoomEntities()) do
        local name = entity:GetData().name
        if name ~= nil then
            local color = entity:GetData().color
            local index = entity:GetData().index
            local pos = Isaac.WorldToScreen(entity.Position)
            if isMirrored then
                pos.X = screenWidth - pos.X
            end
            pos.X = pos.X - font:GetStringWidthUTF8(name) / 4
            pos.Y = pos.Y - entity.Size / 2 - 3
            if allNameNpcTbl[name] == nil then
                allNameNpcTbl[name] = {}
            end
            table.insert(allNameNpcTbl[name], {index, pos.X, pos.Y, color})
        end
    end
    for name, tbl in pairs(allNameNpcTbl) do -- tbl = {{index, pos.X, pos.Y, color},{index, pos.X, pos.Y, color},...,{index, pos.X, pos.Y, color}}
        local minIndex = 0
        local toBeRenderedTbl = {}
        for k, attr in ipairs(tbl) do
            if minIndex == 0 then
                minIndex = attr[1]
                toBeRenderedTbl = {name, k}
            else
                if attr[1] < minIndex then
                    minIndex = attr[1]
                    toBeRenderedTbl = {name, k}
                end
            end
        end
        font:DrawStringScaledUTF8(toBeRenderedTbl[1], allNameNpcTbl[toBeRenderedTbl[1]][toBeRenderedTbl[2]][2], allNameNpcTbl[toBeRenderedTbl[1]][toBeRenderedTbl[2]][3], 0.5, 0.5, KColor(allNameNpcTbl[toBeRenderedTbl[1]][toBeRenderedTbl[2]][4][1], allNameNpcTbl[toBeRenderedTbl[1]][toBeRenderedTbl[2]][4][2], allNameNpcTbl[toBeRenderedTbl[1]][toBeRenderedTbl[2]][4][3], 1), 0, false)
    end
    --render QR code
    if cookieState == cookieStateTable.QRCODE_READY or cookieState == cookieStateTable.TO_BE_SCANNED or cookieState == cookieStateTable.TO_BE_CONFIRMED or cookieState == cookieStateTable.WAIT_SCAN_RESPONSE then
        diplayQRCode()
    end
end

mod:AddCallback(ModCallbacks.MC_POST_NPC_INIT, onPostNpcInit)
mod:AddCallback(ModCallbacks.MC_POST_PICKUP_INIT, onPostPickupInit)
mod:AddCallback(ModCallbacks.MC_POST_GAME_STARTED, onGameStart)
mod:AddCallback(ModCallbacks.MC_POST_UPDATE, onUpdate)
mod:AddCallback(ModCallbacks.MC_POST_RENDER, onRender)