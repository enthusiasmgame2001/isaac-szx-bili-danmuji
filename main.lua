-- global variables
szxDanmuji = {}
szxDanmuji.danmuTable = {}
szxDanmuji.danmuCommandOn = false
local ttt = 0
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
	local modPathEnd, _ = string.find(err, "mods", modPathStart)
	local path = string.sub(err, modPathStart + 1, modPathEnd - 1)
	path = string.gsub(path, "\\", "/")
	path = string.gsub(path, "//", "/")
	path = string.gsub(path, ":/", ":\\")
	font:Load(path .. "mods/szx_bili_danmuji_3034585714/resources/font/cjk/lanapixel.fnt")
end
loadFont()

-- text variables
local modVersion = "三只熊弹幕姬v1.6"
local inputBoxText = "请黏贴直播间号：[LCtrl + v]"
local instuctionText1 = "在任何情况下"
local instuctionText2 = "按 [LCtrl + z] 即可重置连接"
local instuctionText3 = "按 [LCtrl + x] 开关弹幕姬"
local instuctionText4 = "按 [LAlt + x] 开关弹幕互动 (观众发送弹幕'生成c1'会生成1号道具')"

local getTokenPartUrl = "https://api.live.bilibili.com/xlive/web-room/v1/index/getDanmuInfo?id="
local getQRCodeUrl = "https://passport.bilibili.com/x/passport-login/web/qrcode/generate"
local getQRCodeScanResponsePartUrl = "https://passport.bilibili.com/x/passport-login/web/qrcode/poll?qrcode_key="
local danmuWsAddress = "wss://broadcastlv.chat.bilibili.com:443/sub"

local initHeader12 = "\x00\x00\x00\x2F\x00\x10\x00\x01\x00\x00\x00\x07"
local initUid = "\x7B\x22\x75\x69\x64\x22\x3A\x32\x38\x31\x39\x33\x37\x37\x35" -- {"uid":28193775 [[szx's uid]]
local initRoomIdKey = "\x2C\x22\x72\x6F\x6F\x6D\x69\x64\x22\x3A" -- ,"roomid":
local initRoomIdValue = "3092145" -- lanbing's bilibili roomid
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

--danmu variables
local curDanmu = {"", "", ""}
local speechTimer = 0
local roomId = ""

--QR code variables
local spriteQRCodeTable = {}
local qRCodeSequence = {}
local qRCodeDimension = nil
local qRCodeStartPos = {200, 50}
local cookieStateTable = {
    INIT = 0, --初始状态，未启动getCookie过程
    START = 1, --开始getCookie过程
    WAITQRCODEREADY = 2, --等待生成二维码请求的响应
    QRCODEREADY = 3, --二维码已生成
    WAITSCANRESPONSE = 4, --等待获得二维码扫描情况的响应
    SUCCESS = 5, --扫码登录成功
    EXPIRED = 6, --二维码已失效
    TOBECONFIRMED = 7, --用户已扫码，等待用户确认
    TOBESCANNED = 8, --用户未代码，等待用户扫码
    END = 9 --完成getCookie过程
}
local cookieState = cookieStateTable.INIT
local qrCodeKey = ""
local userCookieUrl = ""
local qrRequestTimer = 0

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
    font:DrawStringUTF8(modVersion, 275, 193, KColor(1, 1, 1, 1), 0, false)
    font:DrawStringUTF8(inputBoxText, 250, 218, KColor(1, 1, 1, 1), 0, false)
    font:DrawStringUTF8(instuctionText1, 60, 168, KColor(1, 0.75, 0, 1), 0, false)
    font:DrawStringUTF8(instuctionText2, 60, 193, KColor(1, 0.75, 0, 1), 0, false)
    font:DrawStringUTF8(instuctionText3, 60, 218, KColor(1, 0.75, 0, 1), 0, false)
    font:DrawStringUTF8(instuctionText4, 60, 243, KColor(1, 0.75, 0, 1), 0, false)
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

function isWsNil()
    print(ws == nil)
end

function printAll()
    print(allTimerStop)
end

local function getCurDanmu(message)
    local p = 1
    while p + 15 <= #message do
        local packetLength, headerLength, protoVersion, packetType, _, offset = string.unpack(">I4I2I2I4I4", message,p)
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
                    speechTimer = 600
                    if szxDanmuji.danmuCommandOn then
                        table.insert(szxDanmuji.danmuTable, curDanmu[1])
                    end
                end
            elseif commandType == "POPULARITY_RED_POCKET_NEW" then --留言红包
                local data = messageTable.data
                curDanmu[1] = "送出了1个红包[" .. data.price .. "金电池]"
                curDanmu[2] = data.uname
                curDanmu[3] = ""
                speechTimer = 600
            elseif commandType == "GUARD_BUY" then --上舰
                local data = messageTable.data
                local guardNameTable = {"总督", "提督", "舰长"}
                curDanmu[1] = "开通了" .. data.num .. "个月" .. guardNameTable[data.guard_level]
                curDanmu[2] = messageTable.data.username
                curDanmu[3] = ""
                speechTimer = 600
            elseif commandType == "SUPER_CHAT_MESSAGE" then --醒目留言
                local data = messageTable.data
                curDanmu[1] = data.message .. "[醒目留言:" .. data.price .. "元]"
                curDanmu[2] = data.user_info.uname
                curDanmu[3] = ""
                speechTimer = 600
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
                speechTimer = 600
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
    local header = initHeader12:sub(1,3) .. string.char(54 + #initRoomIdValue + #initToken) .. initHeader12:sub(5) .. headerSequenceBytes
    local packet = header .. initUid .. initRoomIdKey .. initRoomIdValue .. initProtoVersion .. initToken
    ws.Send(packet, true)
    curDanmu[1] = ""
    curDanmu[2] = ""
    curDanmu[3] = {"连接成功", 2}
    local saveDataTable = {}
    saveDataTable.roomId = roomId
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
    if IsaacSocket ~= nil and IsaacSocket.IsConnected() then
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
    if IsaacSocket ~= nil and IsaacSocket.IsConnected() then
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

local function executeDanmuCommand(str)
    if #str > 7 then
        if str:sub(1, 6) == "生成" then
            local code = str:sub(7)
            if elementInList(code:lower(), itemOrderMap) then
                local prefix = code:sub(1, 1)
                local subType = code:sub(2)
                if codeCommandMapTable[prefix][2] then
                    subType = subType + 32768
                end
                local curCommand = codeCommandMapTable[prefix][1] .. subType
                Isaac.ExecuteCommand(curCommand)
            end
        end
    end
end

local function updateAllTimerStop(mode)
    allTimerStop = mode
end

local function updateCookieState()
    if cookieState == cookieStateTable.INIT then
        cookieState = cookieStateTable.START
    elseif cookieState == cookieStateTable.START or cookieState == cookieStateTable.EXPIRED then
        cookieState = cookieStateTable.WAITQRCODEREADY
        local url = getQRCodeUrl
        local headers = {}
        print("yibuqingqiu")
        IsaacSocket.HttpClient.GetAsync(url, headers).Then(function(task)
            if task.IsCompletedSuccessfully() then
                local response = task.GetResult()
                local body = json.decode(response.body)
                if body.code == 0 then
                    initQRCodeSequence(body.data.url)
                    qrCodeKey = body.data.qrcode_key
                    cookieState = cookieStateTable.QRCODEREADY
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
    elseif cookieState == cookieStateTable.QRCODEREADY or cookieState == cookieStateTable.TOBESCANNED or cookieState == cookieStateTable.TOBECONFIRMED then
        cookieState = cookieStateTable.WAITSCANRESPONSE
        local url = getQRCodeScanResponsePartUrl .. qrCodeKey
        local headers = {}
        print("yibuqingqiu")
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
                    elseif responseCode == 86038 then
                        qrCodeKey = ""
                        cookieState = cookieStateTable.EXPIRED
                    elseif responseCode == 86090 then
                        cookieState = cookieStateTable.TOBECONFIRMED
                    elseif responseCode == 86101 then
                        cookieState = cookieStateTable.TOBESCANNED
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
        print(userCookieUrl)
    end
end

local function getTokenAndCreateWebSocketObject(useClipboard)
    if ws == nil then     
        if IsaacSocket ~= nil and IsaacSocket.IsConnected() then
            if useClipboard then
                local pasteText = IsaacSocket.Clipboard.GetClipboard()
                if #pasteText == 0 then
                    curDanmu[1] = ""
                    curDanmu[2] = ""
                    curDanmu[3] = {"剪贴板为空", 1}
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
                    else
                        curDanmu[1] = ""
                        curDanmu[2] = ""
                        curDanmu[3] = {"剪贴板非纯数字", 1}
                        speechTimer = 150
                        return
                    end
                end
            else
                initRoomIdValue = roomId
                curDanmu[1] = ""
                curDanmu[2] = ""
                curDanmu[3] = {"正在初始化连接", 2}
            end
            inputBoxText = "正在连接直播间：" .. initRoomIdValue
            if qrRequestTimer == 15 then
                updateCookieState()
            end
            if cookieState == cookieStateTable.END then
                local url = getTokenPartUrl .. roomId
                local headers = {
                    ["Cookie"] = "\
                    LIVE_BUVID=AUTO5616960701584697;\
                    buvid4=59FDECD7-121C-29C9-CB7A-01ACC492AC1959054-023093018-AvVeNZ9eYbnk1865fxIaNg%3D%3D; \
                    fingerprint=af29c218b5840cbf708ccf87c6b5d995; \
                    buvid_fp_plain=undefined; \
                    buvid3=FF370740-D72C-BC6D-0727-0FDDBDB5E21970399infoc; \
                    b_nut=1696070170; \
                    b_lsid=E6110212D_18AE5A8FAA1; \
                    _uuid=D85133B1-88610-DD91-7DCE-510107713635A371307infoc; \
                    \
                    DedeUserID=28193775; \
                    DedeUserID__ckMd5=f79f6f05306787b1; \
                    SESSDATA=86547e04%2C1711622318%2C9233d%2A92CjBw6iX9WJHsL7XyngWNFR4pST6yylrnWW9nA5obX19Ecyyp6As8vknK_mX7S-JfZ1YSVmJ6NzdnQnVZblNLUTRKNGxaV0tmT2hHai1IN3FqanktOXV0TnlvcUhHXzhIWWVqa0J1WkhUUTJiRmg4YkxVdWRiTTZ2cEtfTWdFaXJYcWNXVTBGTWlnIIEC; \
                    bili_jct=900734dce074bf54c791b7aa8641e2a3; \
                    \
                    header_theme_version=CLOSE; \
                    home_feed_column=4; \
                    browser_resolution=1280-603; \
                    CURRENT_FNVAL=4048; \
                    rpdid=|(Jkl~uRlYJY0J'uYmY|~|J~R; \
                    sid=7jlrrw2c; \
                    bili_ticket=eyJhbGciOiJIUzI1NiIsImtpZCI6InMwMyIsInR5cCI6IkpXVCJ9.eyJleHAiOjE2OTYzMzAxMTIsImlhdCI6MTY5NjA3MDg1MiwicGx0IjotMX0.RT9pBwllbJccy-d0FsqfiyrVRYAxZGqXvrAZBHwQFKA; \
                    bili_ticket_expires=1696330052; \
                    buvid_fp=af29c218b5840cbf708ccf87c6b5d995; \
                    bp_video_offset_28193775=847111402115039268; \
                    PVID=4\
                    "
                }
                allTimerStop = true
                print("yibuqingqiu")
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
                    updateAllTimerStop(false)
                end)
            end
        else
            curDanmu[1] = ""
            curDanmu[2] = ""
            curDanmu[3] = {"IsaacSocket未正常工作(连接直播间)", 1}
        end
        speechTimer = 150
    end
end

local function onGameStart(_, IsContinued)
    allTimerStop = false
    needAnimate = {false, false}
    szxDanmuji.danmuTable = {}
    updateItemTables()
end

local function onUpdate()
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
    local isAltPressed = Input.IsButtonPressed(Keyboard.KEY_LEFT_ALT, 0)
    if isAltPressed and Input.IsButtonTriggered(Keyboard.KEY_X, 0) then
        szxDanmuji.danmuCommandOn = not szxDanmuji.danmuCommandOn
        if szxDanmuji.danmuCommandOn then
            needAnimate[1] = true
            curDanmu[1] = "例：生成c1 生成t2 生成T3 生成k4"
            curDanmu[2] = ""
            curDanmu[3] = {"弹幕互动打开", 2}
        else
            needAnimate[2] = true
            curDanmu[1] = ""
            curDanmu[2] = ""
            curDanmu[3] = {"弹幕互动关闭", 1}
        end
        speechTimer = 150
    end
    if isCtrlPressed and Input.IsButtonTriggered(Keyboard.KEY_X, 0) then
        if ws ~= nil then
            closeWebSocket()
            speechTimer = 150
        end
        ws = nil
        timer = 0
        sequence = 1
        roomLatencyTimer = 0
        roomId = ""
        inputBoxText = "请黏贴直播间号：[LCtrl + v]"
        danmujiOn = not danmujiOn
    end
    if isCtrlPressed and Input.IsButtonTriggered(Keyboard.KEY_Z, 0) then
        if ws ~= nil then
            closeWebSocket()
            speechTimer = 150
        end
        ws = nil
        timer = 0
        sequence = 1
        roomLatencyTimer = 0
        roomId = ""
        inputBoxText = "请黏贴直播间号：[LCtrl + v]"
        local saveDataTable = {}
        mod:SaveData(json.encode(saveDataTable))
    end
    if danmujiOn and (ws == nil or roomLatencyTimer < 300) and not allTimerStop then
        displayTitle()
        local jsonTable = {}
        if mod:HasData() then
            jsonTable = json.decode(mod:LoadData())
        end
        if jsonTable.roomId ~= nil and jsonTable.roomId ~= "" then
            roomId = jsonTable.roomId
        end
        if roomId ~= "" then
            getTokenAndCreateWebSocketObject(false)
        end
        if isCtrlPressed and Input.IsButtonTriggered(Keyboard.KEY_V, 0) then
            getTokenAndCreateWebSocketObject(true)
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
        if IsaacSocket ~= nil and IsaacSocket.IsConnected() then
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
    if speechTimer > 0 then
        local player = Isaac.GetPlayer(0)
        local room = Game():GetRoom()
        local pos = Isaac.WorldToScreen(player.Position)
        if room:IsMirrorWorld() then
            pos.X = Isaac.GetScreenWidth() - pos.X
        end
        if curDanmu[1] ~= "" then 
            font:DrawStringUTF8(curDanmu[1], pos.X - font:GetStringWidthUTF8(curDanmu[1]) / 2, pos.Y - 36 * player.SpriteScale.Y - 8 - font:GetLineHeight(), KColor(1, 1, 1, 1), 0, false)
        end
        if curDanmu[2] ~= "" then
            font:DrawStringUTF8(curDanmu[2], pos.X - font:GetStringWidthUTF8(curDanmu[2]) / 2, pos.Y + 16 - font:GetLineHeight(), KColor(1, 0.75, 0, 1), 0, false)
        end
        if curDanmu[3] ~= "" then
            if curDanmu[3][2] == 1 then
                font:DrawStringUTF8(curDanmu[3][1], pos.X - font:GetStringWidthUTF8(curDanmu[3][1]) / 2, pos.Y + 16 - font:GetLineHeight(), KColor(0.8, 0.1, 0.1, 1), 0, false)
            elseif curDanmu[3][2] == 2 then
                font:DrawStringUTF8(curDanmu[3][1], pos.X - font:GetStringWidthUTF8(curDanmu[3][1]) / 2, pos.Y + 16 - font:GetLineHeight(), KColor(0.1, 0.8, 0.1, 1), 0, false)
            elseif curDanmu[3][2] == 3 then
                font:DrawStringUTF8(curDanmu[3][1], pos.X - font:GetStringWidthUTF8(curDanmu[3][1]) / 2, pos.Y + 16 - font:GetLineHeight(), KColor(1, 0.75, 0, 1), 0, false)
            end
        end
    end
    if cookieState == cookieStateTable.QRCODEREADY or cookieState == cookieStateTable.TOBESCANNED or cookieState == cookieStateTable.TOBECONFIRMED or cookieState == cookieStateTable.WAITSCANRESPONSE then
        diplayQRCode()
    end 
    --test
    ttt = ttt + 1
    if ttt == 120 then
        ttt = 1
    end
    if ttt == 30 then
        for k, v in pairs(cookieStateTable) do
            if v == cookieState then
                print("cookieState=", k)
                break
            end
        end
    end
end

mod:AddCallback(ModCallbacks.MC_POST_GAME_STARTED, onGameStart)
mod:AddCallback(ModCallbacks.MC_POST_UPDATE, onUpdate)
mod:AddCallback(ModCallbacks.MC_POST_RENDER, onRender)