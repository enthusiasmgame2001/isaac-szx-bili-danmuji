-- import the zzlib library
local zzlib = require("zzlib")

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
local modVersion = "三只熊弹幕姬v1.0"
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
    mod:SaveData(output)
    if string.find(output, '"cmd":"DANMU_MSG"') then
        local startIndex, endIndex = string.find(output, '\\"content\\":\\"')
        if startIndex then
            local contentStartIndex = endIndex + 1
            local contentEndIndex = string.find(output, '\\"', contentStartIndex)
            if contentEndIndex then
                local content = string.sub(output, contentStartIndex, contentEndIndex - 1)
                curDanmu[1] = content
                local restOutput = output:sub(contentEndIndex + 1)
                local secondContentStartIndex, secondContentEndIndex = string.find(restOutput, '"'..content..'",')
                if secondContentEndIndex then
                    local lastOutput = restOutput:sub(secondContentEndIndex + 1)
                    local startIdx, endIdx = string.find(lastOutput, ',"')
                    if startIdx then
                        local nameStartIndex = endIdx + 1
                        local nameEndIndex = string.find(lastOutput, '"', nameStartIndex)
                        local name = string.sub(lastOutput, nameStartIndex, nameEndIndex - 1)
                        curDanmu[2] = name
                    else
                        curDanmu[2] = "nil"
                    end
                else
                    curDanmu[2] = "nil"
                end
            else
                curDanmu[1] = "nil"
                curDanmu[2] = "nil"
            end
            curDanmu[3] = ""
        else
            curDanmu[1] = ""
            curDanmu[2] = ""
            curDanmu[3] = '"content" not in message'
        end
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
        curDanmu[3] = "Execute sending init packet"
    else
        curDanmu[1] = ""
        curDanmu[2] = ""
        curDanmu[3] = "WebSocketClient is not open"
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
        curDanmu[3] = "WebSocketClient is not open"
        speechTimer = 150
    end
end

local function closeWebSocket()
    if IsaacSocket ~= nil and IsaacSocket.IsConnected() then
        ws.Close(IsaacSocket.WebSocketClient.CloseStatus.NORMAL, "Normal Closure")
        curDanmu[1] = ""
        curDanmu[2] = ""
        curDanmu[3] = "Execute normal closure"
    else
        curDanmu[1] = ""
        curDanmu[2] = ""
        curDanmu[3] = "IsaacSocket is not connected"
    end
end

local function CallbackOnOpen()
    curDanmu[1] = ""
    curDanmu[2] = ""
    curDanmu[3] = "Open"
    speechTimer = 150
end

local function CallbackOnMessage(message, isBinary)
    if isBinary then
        if message:sub(5,12) == "\x00\x10\x00\x02\x00\x00\x00\x05" then
            local output = zzlib.inflate(message:sub(17))
            getCurDanmu(output)
            speechTimer = 600
        end
        print("Binary Message, length = " .. #message)
    else
        curDanmu[1] = ""
        curDanmu[2] = ""
        curDanmu[3] = "Text Message: " .. message
        speechTimer = 600
    end
end

local function CallbackOnClose(closeStatus, message)
    curDanmu[1] = ""
    curDanmu[2] = ""
    curDanmu[3] = "Close: [" .. closeStatus .. "]" .. message
    speechTimer = 150
end

local function CallbackOnError(message)
    curDanmu[1] = ""
    curDanmu[2] = ""
    curDanmu[3] = "Error: " .. message
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
                    curDanmu[3] = "Clipboard is empty"
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
                        curDanmu[3] = "A new ws object was set"
                    else
                        curDanmu[1] = ""
                        curDanmu[2] = ""
                        curDanmu[3] = "room id is illegal"
                    end
                end
            else
                curDanmu[1] = ""
                curDanmu[2] = ""
                curDanmu[3] = "IsaacSocket is not connected"
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
                curDanmu[3] = "ws object is nil" 
            end
        else
            curDanmu[1] = ""
            curDanmu[2] = ""
            curDanmu[3] = "IsaacSocket is not connected"
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
                curDanmu[3] = "ws object is nil" 
                speechTimer = 150
            end
        else
            curDanmu[1] = ""
            curDanmu[2] = ""
            curDanmu[3] = "IsaacSocket is not connected"
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
            font:DrawStringUTF8(curDanmu[2], pos.X - font:GetStringWidthUTF8(curDanmu[2]) / 2, pos.Y + 16 - font:GetLineHeight(), KColor(1, 1, 1, 1), 0, false)
        end
        if curDanmu[3] ~= "" then
            font:DrawStringUTF8(curDanmu[3], pos.X - font:GetStringWidthUTF8(curDanmu[3]) / 2, pos.Y + 16 - font:GetLineHeight(), KColor(0.8, 0.1, 0.1, 1), 0, false)
        end
    end
end

mod:AddCallback(ModCallbacks.MC_POST_UPDATE, onUpdate)
mod:AddCallback(ModCallbacks.MC_POST_RENDER, onRender)