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
local modVersion = "三只熊弹幕姬v1.1"
local inputBoxText = "请黏贴直播间号：[LCtrl + v]"
local instuctionText1 = "在任何情况下"
local instuctionText2 = "按 [LCtrl + z] 即可重置连接"
local instuctionText3 = "按 [LCtrl + x] 开关弹幕姬"

local address = "wss://broadcastlv.chat.bilibili.com:443/sub"

local initHeader12 = "\x00\x00\x00\x2F\x00\x10\x00\x01\x00\x00\x00\x07"
local initHeaderRoomIdKey = "\x7B\x22\x72\x6F\x6F\x6D\x69\x64\x22\x3A" -- {"roomid":
local initHeaderRoomIdValue = "1174749" -- szx's bilibili roomid
local initHeaderProtoVersion = "\x2C\x22\x70\x72\x6F\x74\x6F\x76\x65\x72\x22\x3A\x32\x7D" -- ,"protover":2}

local heartHeader12 = "\x00\x00\x00\x13\x00\x10\x00\x01\x00\x00\x00\x02"
local heartText = "\x73\x7A\x78" -- szx

--state variables
local ws = nil
local danmujiOn = true
local sequence = 1
local timer = 0
local roomLatencyTimer = 0

--danmu variables
local curDanmu = {"", "", ""}
local speechTimer = 0

local function displayTitle()
    font:DrawStringUTF8(modVersion, 275, 193, KColor(1, 1, 1, 1), 0, false)
    font:DrawStringUTF8(inputBoxText, 250, 218, KColor(1, 1, 1, 1), 0, false)
    font:DrawStringUTF8(instuctionText1, 60, 168, KColor(1, 0.75, 0, 1), 0, false)
    font:DrawStringUTF8(instuctionText2, 60, 193, KColor(1, 0.75, 0, 1), 0, false)
    font:DrawStringUTF8(instuctionText3, 60, 218, KColor(1, 0.75, 0, 1), 0, false)
end

local function getCurDanmu(output)
    local message = output:sub(17)
    local messageTable = json.decode(message)
    local commandType = messageTable.cmd
    if commandType:sub(1, 9) == "DANMU_MSG" then --弹幕
        curDanmu[1] = messageTable.info[2]
        curDanmu[2] = messageTable.info[3][2]
        curDanmu[3] = ""
    elseif commandType == "POPULARITY_RED_POCKET_NEW" then --留言红包
        local data = messageTable.data
        curDanmu[1] = "送出了1个红包[" .. data.price .. "金电池]"
        curDanmu[2] = data.uname
        curDanmu[3] = ""
    elseif commandType == "GUARD_BUY" then --上舰
        local data = messageTable.data
        local guardNameTable = {"总督", "提督", "舰长"}
        curDanmu[1] = "开通了" .. data.num .. "个月" .. guardNameTable[data.guard_level]
        curDanmu[2] = messageTable.data.username
        curDanmu[3] = ""
    elseif commandType == "SUPER_CHAT_MESSAGE" then --醒目留言
        local data = messageTable.data
        curDanmu[1] = data.message .. "[醒目留言:" .. data.price .. "元]"
        curDanmu[2] = data.user_info.uname
        curDanmu[3] = ""
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
    end
end

local function getSequenceBytes(seq)
    local seqBytes = string.char((seq >> 24) & 0xFF, (seq >> 16) & 0xFF, (seq >> 8) & 0xFF, seq & 0xFF)

    return seqBytes
end

local function sendInitPacket()
    local headerSequenceBytes = getSequenceBytes(sequence)
    local header = initHeader12:sub(1,3) .. string.char(40 + #initHeaderRoomIdValue) .. initHeader12:sub(5) .. headerSequenceBytes
    local packet = header .. initHeaderRoomIdKey .. initHeaderRoomIdValue ..initHeaderProtoVersion
    if ws.GetState() == IsaacSocket.WebSocketClient.State.OPEN then
        ws.Send(packet, true)
        curDanmu[1] = ""
        curDanmu[2] = ""
        curDanmu[3] = {"连接成功", 2}
    else
        curDanmu[1] = ""
        curDanmu[2] = ""
        curDanmu[3] = {"认证包发送失败", 1}
    end
end

local function sendHeartBeatPacket()
    local headerSequenceBytes = getSequenceBytes(sequence)
    local header = heartHeader12 .. headerSequenceBytes
    local packet = header .. heartText
    if ws.GetState() == IsaacSocket.WebSocketClient.State.OPEN then
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
        ws.Close(IsaacSocket.WebSocketClient.CloseStatus.NORMAL, "Normal Closure")
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
    curDanmu[1] = ""
    curDanmu[2] = ""
    curDanmu[3] = {"正在启动连接", 2}
    speechTimer = 150
end

local function CallbackOnMessage(message, isBinary)
    if isBinary then
        if message:sub(5,12) == "\x00\x10\x00\x02\x00\x00\x00\x05" then
            local output = zzlib.inflate(message:sub(17))
            getCurDanmu(output)
            speechTimer = 600
        end
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

local function onUpdate()
    if speechTimer > 0 then
        speechTimer = speechTimer - 1
    end
end

local function onRender(_)
    local isCtrlPressed = Input.IsButtonPressed(Keyboard.KEY_LEFT_CONTROL, 0)
    if isCtrlPressed and Input.IsButtonTriggered(Keyboard.KEY_X, 0) then
        if ws ~= nil then
            closeWebSocket()
            speechTimer = 150
        end
        ws = nil
        timer = 0
        sequence = 1
        roomLatencyTimer = 0
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
        inputBoxText = "请黏贴直播间号：[LCtrl + v]"
    end
    if danmujiOn and (ws == nil or roomLatencyTimer < 300) then
        displayTitle()
        if isCtrlPressed and Input.IsButtonTriggered(Keyboard.KEY_V, 0) then
            if IsaacSocket ~= nil and IsaacSocket.IsConnected() then
                local pasteText = IsaacSocket.Clipboard.GetClipboard()
                if #pasteText == 0 then
                    curDanmu[1] = ""
                    curDanmu[2] = ""
                    curDanmu[3] = {"剪贴板为空", 1}
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
                        inputBoxText = "正在连接直播间：" .. pasteText
                        ws = IsaacSocket.WebSocketClient.New(address, CallbackOnOpen, CallbackOnMessage, CallbackOnClose, CallbackOnError)
                        initHeaderRoomIdValue = pasteText
                        curDanmu[1] = ""
                        curDanmu[2] = ""
                        curDanmu[3] = {"正在初始化连接", 2}
                    else
                        curDanmu[1] = ""
                        curDanmu[2] = ""
                        curDanmu[3] = {"剪贴板非纯数字", 1}
                    end
                end
            else
                curDanmu[1] = ""
                curDanmu[2] = ""
                curDanmu[3] = {"IsaacSocket未正常工作(连接直播间)", 1}
            end
            speechTimer = 150
        end 
    end
    if ws ~= nil then
        timer = timer + 1
        if roomLatencyTimer < 300 then
            roomLatencyTimer = roomLatencyTimer + 1
        end
    end
    if timer == 150 and sequence == 1 then
        if IsaacSocket ~= nil and IsaacSocket.IsConnected() then
            if ws ~= nil then
                sendInitPacket()
                sequence = sequence + 1
            else
                curDanmu[1] = ""
                curDanmu[2] = ""
                curDanmu[3] = {"websocket对象为空(请把这条消息告诉作者谢谢)", 1}
            end
        else
            curDanmu[1] = ""
            curDanmu[2] = ""
            curDanmu[3] = {"IsaacSocket未正常工作(发送认证包)", 1}
        end
        speechTimer = 150
    end
    if timer >= 1800 then
        timer = 0
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
end

mod:AddCallback(ModCallbacks.MC_POST_UPDATE, onUpdate)
mod:AddCallback(ModCallbacks.MC_POST_RENDER, onRender)