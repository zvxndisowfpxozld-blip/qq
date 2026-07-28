script_name("SF Integration")
script_version("1.6")
script_version_number(16)
script_author("FYP")
script_description("integrate MoonLoader with SAMPFUNCS")
script_properties('work-in-pause')

require "lib.sampfuncs"
require "lib.moonloader"
local vkeys = require 'lib.vkeys'
local ffi = require "ffi"
local vector = require "vector3d"
local sampev = require('samp.events')
local imgui = require('mimgui')
local encoding = require('encoding')

encoding.default = 'CP1251'

local function isMonser01()
    if not isSampAvailable() then return false end
    local ip, port = sampGetCurrentServerAddress()
    local name = sampGetCurrentServerName()
    return ip == "185.71.66.13" or (name:lower():find("monser") and (name:find("01") or name:find("1")))
end

local lastReportSender = -1
local lastReportTarget = -1

local activeReportSender = -1
local activeReportTarget = -1

local currentReportDialogId = -1

local showOwnKeys = false
local warningsEnabled = false

local lastWarnTime = {}
local playerChatHistory = {}
local cbugTracker = {}

TAG = {
    TYPE_INFO      = 1,
    TYPE_DEBUG     = 2,
    TYPE_ERROR     = 3,
    TYPE_WARN      = 4,
    TYPE_SYSTEM    = 5,
    TYPE_FATAL     = 6,
    TYPE_EXCEPTION = 7
}

local tracersEnabled = true
local bullets = {}

local TRACER_LIFETIME = 2.0
local LINE_THICKNESS = 1.5
local CIRCLE_RADIUS = 3.0

local COLOR_HIT    = imgui.ImVec4(0.0, 1.0, 0.0, 0.8)
local COLOR_MISS   = imgui.ImVec4(1.0, 0.0, 0.0, 0.8)
local COLOR_SILENT = imgui.ImVec4(1.0, 0.5, 0.0, 0.8)

local specStats = {
    shots = 0,
    hits = 0,
    misses = 0,
    head = 0,
    belly = 0,
    shoulders = 0,
    legs = 0
}

local function resetSpecStats()
    specStats.shots = 0
    specStats.hits = 0
    specStats.misses = 0
    specStats.head = 0
    specStats.belly = 0
    specStats.shoulders = 0
    specStats.legs = 0
end

local frameDrawList = imgui.OnFrame(
    function() return isMonser01() and tracersEnabled and #bullets > 0 and not isPauseMenuActive() end,
    function(self)
        self.HideCursor = true
        local DL = imgui.GetBackgroundDrawList()
        local now = os.clock()

        for i = #bullets, 1, -1 do
            local b = bullets[i]
            local elapsed = now - b.clock

            if elapsed >= TRACER_LIFETIME then
                table.remove(bullets, i)
            else
                local alpha = math.max(0, b.color.w * (1 - (elapsed / TRACER_LIFETIME)))
                local color = imgui.ImVec4(b.color.x, b.color.y, b.color.z, alpha)
                local u32Color = imgui.GetColorU32Vec4(color)

                local _, oX, oY, oZ = convert3DCoordsToScreenEx(b.origin.x, b.origin.y, b.origin.z, false, false)
                local _, tX, tY, tZ = convert3DCoordsToScreenEx(b.target.x, b.target.y, b.target.z, false, false)

                if oZ > 0 and tZ > 0 then
                    DL:AddLine(imgui.ImVec2(oX, oY), imgui.ImVec2(tX, tY), u32Color, LINE_THICKNESS)
                    DL:AddCircleFilled(imgui.ImVec2(tX, tY), CIRCLE_RADIUS, u32Color, 12)
                end
            end
        end
    end
)

local AIM_LENGTH = 2.0
local AIM_TRANSITION = 0.5
local AIM_DISTANCE = 100

local aimState = true
local aimCam = {}
local getBonePosition = ffi.cast("int (__thiscall*)(void*, float*, int, bool)", 0x5E4280)

function bringFloatTo(from, dest, start_time, duration)
    local timer = os.clock() - start_time
    if timer >= 0.00 and timer <= duration then
        local count = timer / (duration / 100)
        return from + (count * (dest - from) / 100)
    end
    return (timer > duration) and dest or from
end

function getBodyPartCoordinates(id, handle)
    local ptr = getCharPointer(handle)
    if ptr ~= 0 then
        local pos = ffi.new("float[3]")
        getBonePosition(ffi.cast("void*", ptr), pos, id, true)
        return true, vector(pos[0], pos[1], pos[2])
    end
    return false
end

function aimSyncRenderer()
    if isMonser01() and aimState and not isPauseMenuActive() and not sampIsScoreboardOpen() then
        local meX, meY, meZ = getActiveCameraCoordinates()
        for ped, data in pairs(aimCam) do
            if doesCharExist(ped) then
                local result, headPos = getBodyPartCoordinates(8, ped)
                if result then
                    if AIM_DISTANCE ~= -1 and getDistanceBetweenCoords3d(meX, meY, meZ, headPos:get()) > AIM_DISTANCE then
                        goto continue
                    end

                    local offset = vector(
                        bringFloatTo(data.old.x, data.new.x, data.timer, AIM_TRANSITION),
                        bringFloatTo(data.old.y, data.new.y, data.timer, AIM_TRANSITION),
                        bringFloatTo(data.old.z, data.new.z, data.timer, AIM_TRANSITION)
                    )
                    
                    local camPos = headPos + offset
                    local full_len = (camPos - headPos):length()
                    if full_len > 0.0001 then
                        camPos = headPos + (camPos - headPos) * (AIM_LENGTH / full_len)

                        local _, pX, pY, pZ, _, _ = convert3DCoordsToScreenEx( headPos:get() )
                        local _, cX, cY, cZ, _, _ = convert3DCoordsToScreenEx( camPos:get() )

                        if pZ > 1 and cZ > 1 then
                            renderDrawLine(pX, pY, cX, cY, 2, 0x30FFFFFF)
                            renderDrawPolygon(cX, cY, 4, 4, 8, 0, 0xFFFFFFFF)
                        end
                    end
                end
            else
                aimCam[ped] = nil
            end
            ::continue::
        end
    end
end

local keysyncTargetId = -1
local keysyncKeys = {
    ["onfoot"] = {},
    ["vehicle"] = {}
}
local sW, sH = 0, 0
local u32 = imgui.ColorConvertFloat4ToU32
local KEYCAP = {}

function cyrillic(text)
    local convtbl = {
        [230] = 155, [231] = 159, [247] = 164, [234] = 107, [250] = 144, [251] = 168,
        [254] = 171, [253] = 170, [255] = 172, [224] = 097, [240] = 112, [241] = 099, 
        [226] = 162, [228] = 154, [225] = 151, [227] = 153, [248] = 165, [243] = 121, 
        [184] = 101, [235] = 158, [238] = 111, [245] = 120, [233] = 157, [242] = 166, 
        [239] = 163, [244] = 063, [237] = 174, [229] = 101, [246] = 036, [236] = 175, 
        [232] = 156, [249] = 161, [252] = 169, [215] = 141, [202] = 075, [204] = 077, 
        [220] = 146, [221] = 147, [222] = 148, [192] = 065, [193] = 128, [209] = 067, 
        [194] = 139, [195] = 130, [197] = 069, [206] = 079, [213] = 088, [168] = 069, 
        [223] = 149, [207] = 140, [203] = 135, [201] = 133, [199] = 136, [196] = 131, 
        [208] = 080, [200] = 133, [198] = 132, [210] = 143, [211] = 089, [216] = 142, 
        [212] = 129, [214] = 137, [205] = 072, [217] = 138, [218] = 167, [219] = 145
    }
    local result = {}
    for i = 1, string.len(text) do
        local c = text:byte(i)
        result[i] = string.char(convtbl[c] or c)
    end
    return table.concat(result)
end

function bringVec4To(from, dest, start_time, duration)
    local timer = os.clock() - start_time
    if timer >= 0.00 and timer <= duration then
        local count = timer / (duration / 100)
        return imgui.ImVec4(
            from.x + (count * (dest.x - from.x) / 100),
            from.y + (count * (dest.y - from.y) / 100),
            from.z + (count * (dest.z - from.z) / 100),
            from.w + (count * (dest.w - from.w) / 100)
        ), true
    end
    return (timer > duration) and dest or from, false
end

function KeyCap(keyName, isPressed, size)
    local DL = imgui.GetWindowDrawList()
    local p = imgui.GetCursorScreenPos()
    local colors = {
        [true] = imgui.ImVec4(0.60, 0.60, 1.00, 1.00),
        [false] = imgui.ImVec4(0.60, 0.60, 1.00, 0.10)
    }

    if KEYCAP[keyName] == nil then
        KEYCAP[keyName] = {
            status = isPressed,
            color = colors[isPressed],
            timer = nil
        }
    end

    local K = KEYCAP[keyName]
    if isPressed ~= K.status then
        K.status = isPressed
        K.timer = os.clock()
    end

    local rounding = 3.0
    local A = imgui.ImVec2(p.x, p.y)
    local B = imgui.ImVec2(p.x + size.x, p.y + size.y)
    if K.timer ~= nil then
        K.color = bringVec4To(colors[not isPressed], colors[isPressed], K.timer, 0.1)
    end
    local ts = imgui.CalcTextSize(keyName)
    local text_pos = imgui.ImVec2(p.x + (size.x / 2) - (ts.x / 2), p.y + (size.y / 2) - (ts.y / 2))

    imgui.Dummy(size)
    DL:AddRectFilled(A, B, u32(K.color), rounding)
    DL:AddRect(A, B, u32(colors[true]), rounding, 0, 1)
    DL:AddText(text_pos, 0xFFFFFFFF, keyName)
end

imgui.OnInitialize(function()
    sW, sH = getScreenResolution()
    u32 = imgui.ColorConvertFloat4ToU32

    imgui.SwitchContext()
    imgui.GetStyle().WindowPadding = imgui.ImVec2(10, 10)
    imgui.GetStyle().ItemSpacing = imgui.ImVec2(5, 5)
    imgui.GetStyle().WindowRounding = 5.0
    imgui.GetStyle().Colors[imgui.Col.WindowBg] = imgui.ImVec4(0.16, 0.16, 0.22, 0.50)
end)

local function getLocalKeys()
    local k = { ["onfoot"] = {}, ["vehicle"] = {} }
    if isCharInAnyCar(PLAYER_PED) then
        k["vehicle"]["W"] = isKeyDown(vkeys.VK_W) or nil
        k["vehicle"]["A"] = isKeyDown(vkeys.VK_A) or nil
        k["vehicle"]["S"] = isKeyDown(vkeys.VK_S) or nil
        k["vehicle"]["D"] = isKeyDown(vkeys.VK_D) or nil
        k["vehicle"]["Space"] = isKeyDown(vkeys.VK_SPACE) or nil
        k["vehicle"]["Ctrl"] = isKeyDown(vkeys.VK_LCONTROL) or isKeyDown(vkeys.VK_RCONTROL) or nil
        k["vehicle"]["Alt"] = isKeyDown(vkeys.VK_LMENU) or nil
        k["vehicle"]["H"] = isKeyDown(vkeys.VK_H) or nil
        k["vehicle"]["F"] = isKeyDown(vkeys.VK_F) or nil
        k["vehicle"]["Q"] = isKeyDown(vkeys.VK_Q) or nil
        k["vehicle"]["E"] = isKeyDown(vkeys.VK_E) or nil
        k["vehicle"]["Up"] = isKeyDown(vkeys.VK_UP) or nil
        k["vehicle"]["Down"] = isKeyDown(vkeys.VK_DOWN) or nil
    else
        k["onfoot"]["W"] = isKeyDown(vkeys.VK_W) or nil
        k["onfoot"]["A"] = isKeyDown(vkeys.VK_A) or nil
        k["onfoot"]["S"] = isKeyDown(vkeys.VK_S) or nil
        k["onfoot"]["D"] = isKeyDown(vkeys.VK_D) or nil
        k["onfoot"]["Shift"] = isKeyDown(vkeys.VK_LSHIFT) or isKeyDown(vkeys.VK_RSHIFT) or nil
        k["onfoot"]["Alt"] = isKeyDown(vkeys.VK_LMENU) or nil
        k["onfoot"]["Space"] = isKeyDown(vkeys.VK_SPACE) or nil
        k["onfoot"]["C"] = isKeyDown(vkeys.VK_C) or nil
        k["onfoot"]["F"] = isKeyDown(vkeys.VK_F) or nil
        k["onfoot"]["RKM"] = isKeyDown(vkeys.VK_RBUTTON) or nil
        k["onfoot"]["LKM"] = isKeyDown(vkeys.VK_LBUTTON) or nil
    end
    return k
end

imgui.OnFrame(
    function() return isMonser01() and (keysyncTargetId ~= -1 or showOwnKeys) and not isPauseMenuActive() end,
    function(self)
        self.HideCursor = true
        imgui.SetNextWindowPos(imgui.ImVec2(sW / 2, sH - 100), imgui.Cond.Always, imgui.ImVec2(0.5, 0.5))
        imgui.Begin("##KEYS", nil, imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.AlwaysAutoResize)
            
            local activeKeys = keysyncKeys
            local isVehicle = false

            if keysyncTargetId ~= -1 then
                local pedExist, targetPed = sampGetCharHandleBySampPlayerId(keysyncTargetId)
                if pedExist and doesCharExist(targetPed) then
                    isVehicle = not isCharOnFoot(targetPed)
                end
            elseif showOwnKeys then
                activeKeys = getLocalKeys()
                isVehicle = isCharInAnyCar(PLAYER_PED)
            end

            local plState = isVehicle and "vehicle" or "onfoot"

            imgui.BeginGroup()
                imgui.SetCursorPosX(10 + 30 + 5)
                KeyCap("W", (activeKeys[plState]["W"] ~= nil), imgui.ImVec2(30, 30))
                KeyCap("A", (activeKeys[plState]["A"] ~= nil), imgui.ImVec2(30, 30)); imgui.SameLine()
                KeyCap("S", (activeKeys[plState]["S"] ~= nil), imgui.ImVec2(30, 30)); imgui.SameLine()
                KeyCap("D", (activeKeys[plState]["D"] ~= nil), imgui.ImVec2(30, 30))
            imgui.EndGroup()
            imgui.SameLine(nil, 20)

            if plState == "onfoot" then
                imgui.BeginGroup()
                    KeyCap("Shift", (activeKeys[plState]["Shift"] ~= nil), imgui.ImVec2(75, 30)); imgui.SameLine()
                    KeyCap("Alt", (activeKeys[plState]["Alt"] ~= nil), imgui.ImVec2(55, 30))
                    KeyCap("Space", (activeKeys[plState]["Space"] ~= nil), imgui.ImVec2(135, 30))
                imgui.EndGroup()
                imgui.SameLine()
                imgui.BeginGroup()
                    KeyCap("C", (activeKeys[plState]["C"] ~= nil), imgui.ImVec2(30, 30)); imgui.SameLine()
                    KeyCap("F", (activeKeys[plState]["F"] ~= nil), imgui.ImVec2(30, 30))
                    KeyCap("RM", (activeKeys[plState]["RKM"] ~= nil), imgui.ImVec2(30, 30)); imgui.SameLine()
                    KeyCap("LM", (activeKeys[plState]["LKM"] ~= nil), imgui.ImVec2(30, 30))		
                imgui.EndGroup()
            else
                imgui.BeginGroup()
                    KeyCap("Ctrl", (activeKeys[plState]["Ctrl"] ~= nil), imgui.ImVec2(65, 30)); imgui.SameLine()
                    KeyCap("Alt", (activeKeys[plState]["Alt"] ~= nil), imgui.ImVec2(65, 30))
                    KeyCap("Space", (activeKeys[plState]["Space"] ~= nil), imgui.ImVec2(135, 30))
                imgui.EndGroup()
                imgui.SameLine()
                imgui.BeginGroup()
                    KeyCap("Up", (activeKeys[plState]["Up"] ~= nil), imgui.ImVec2(40, 30))
                    KeyCap("Down", (activeKeys[plState]["Down"] ~= nil), imgui.ImVec2(40, 30))	
                imgui.EndGroup()
                imgui.SameLine()
                imgui.BeginGroup()
                    KeyCap("H", (activeKeys[plState]["H"] ~= nil), imgui.ImVec2(30, 30)); imgui.SameLine()
                    KeyCap("F", (activeKeys[plState]["F"] ~= nil), imgui.ImVec2(30, 30))
                    KeyCap("Q", (activeKeys[plState]["Q"] ~= nil), imgui.ImVec2(30, 30)); imgui.SameLine()
                    KeyCap("E", (activeKeys[plState]["E"] ~= nil), imgui.ImVec2(30, 30))
                imgui.EndGroup()
            end
		imgui.End()
    end
)

local function getVerdict()
    if specStats.shots < 5 then
        return "Мало данных", imgui.ImVec4(0.6, 0.6, 0.6, 1.0)
    end
    
    local acc = specStats.hits / specStats.shots
    local maxBoneHits = math.max(specStats.head, specStats.belly, specStats.shoulders, specStats.legs)
    local boneRatio = specStats.hits > 0 and (maxBoneHits / specStats.hits) or 0
    
    if acc >= 0.70 then
        if boneRatio >= 0.60 then
            return "чит (Lock Bone)", imgui.ImVec4(1.0, 0.2, 0.2, 1.0)
        else
            return "подозрительно", imgui.ImVec4(1.0, 0.6, 0.0, 1.0)
        end
    elseif acc >= 0.40 then
        if boneRatio >= 0.75 then
            return "чит (Bone Lock)", imgui.ImVec4(1.0, 0.2, 0.2, 1.0)
        end
        return "легит", imgui.ImVec4(0.2, 1.0, 0.2, 1.0)
    else
        return "не чит", imgui.ImVec4(0.2, 1.0, 0.2, 1.0)
    end
end

imgui.OnFrame(
    function() return isMonser01() and keysyncTargetId ~= -1 and not isPauseMenuActive() end,
    function(self)
        self.HideCursor = true
        imgui.SetNextWindowPos(imgui.ImVec2(15, sH / 2 - 80), imgui.Cond.FirstUseEver)
        
        imgui.PushStyleColor(imgui.Col.WindowBg, imgui.ImVec4(0.0, 0.0, 0.0, 0.85))
        imgui.PushStyleColor(imgui.Col.Border, imgui.ImVec4(0.0, 0.0, 0.0, 0.0))
        imgui.PushStyleVarFloat(imgui.StyleVar.WindowRounding, 3.0)
        
        imgui.Begin("##SPEC_STATS", nil, imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.AlwaysAutoResize)
            imgui.Text(string.format("Кол-во выстрелов: %d", specStats.shots))
            imgui.Text(string.format("Кол-во попаданий: %d", specStats.hits))
            imgui.Text(string.format("Кол-во промахов: %d", specStats.misses))
            imgui.Separator()
            imgui.Text(string.format("Кол-во попаданий в живот: %d", specStats.belly))
            imgui.Text(string.format("Кол-во попаданий в ноги: %d", specStats.legs))
            imgui.Text(string.format("Кол-во попаданий в плечи: %d", specStats.shoulders))
            imgui.Text(string.format("Кол-во попаданий в голову: %d", specStats.head))
            imgui.Separator()
            
            local verdictText, verdictColor = getVerdict()
            imgui.Text("Оценка: ")
            imgui.SameLine()
            imgui.TextColored(verdictColor, verdictText)
        imgui.End()
        
        imgui.PopStyleVar()
        imgui.PopStyleColor(2)
    end
)

logDebugMessages = false

COLOR_MSG       = 0xC0C0C0
COLOR_SCRIPTMSG = 0x7DD156
COLOR_SENDER    = 0xE0E0E0

function main()
  if not isSampfuncsLoaded() then return end
  while not isSampAvailable() do wait(0) end

  addEventHandler("onD3DPresent", aimSyncRenderer)

  sampfuncsRegisterConsoleCommand("lua", do_lua)
  sampfuncsRegisterConsoleCommand(">>", do_lua)

  local function triggerVz()
    if not isMonser01() then return end
    if lastReportSender ~= -1 and lastReportTarget ~= -1 then
      activeReportSender = lastReportSender
      activeReportTarget = lastReportTarget

      if keysyncTargetId ~= activeReportTarget then
          keysyncTargetId = activeReportTarget
          resetSpecStats()
      end

      lua_thread.create(function()
        sampSendChat(string.format("/pm %d Здравствуйте, работаю по Вашей жалобе)))", activeReportSender))
        wait(650)
        sampSendChat(string.format("/re %d", activeReportTarget))
      end)
    else
      sampAddChatMessage("{FF4B4B}[ML] {FFFFFF}Репортов пока не поступало!", -1)
    end
  end

  lua_thread.create(function()
    while true do
      wait(0)
      if isMonser01() and not sampIsChatInputActive() and not isPauseMenuActive() and not sampIsScoreboardOpen() then
        if wasKeyPressed(vkeys.VK_L) then
          triggerVz()
        end
      end
    end
  end)

  sampRegisterChatCommand("wargs", function()
    if not isMonser01() then return end
    warningsEnabled = not warningsEnabled
    local st = warningsEnabled and "{73B461}Включены" or "{FF4B4B}Выключены"
    sampAddChatMessage("{FF4B4B}[ML] {FFFFFF}Админ-варнинги: " .. st, -1)
  end)

  sampRegisterChatCommand("kbi", function()
    if not isMonser01() then return end
    showOwnKeys = not showOwnKeys
    local st = showOwnKeys and "{73B461}Включена" or "{FF4B4B}Выключена"
    sampAddChatMessage("{FF4B4B}[ML] {FFFFFF}Собственная клавиатура: " .. st, -1)
  end)

  sampRegisterChatCommand("vz", function()
    triggerVz()
  end)

  sampRegisterChatCommand("p", function(id)
    if not isMonser01() then return end
    sampSendChat("/pm ".. id .. " Здравствуйте Уважаемый игрок, работаю по Вашей жалобе))")
  end)

  sampRegisterChatCommand("pp", function(id1)
    if not isMonser01() then return end
    sampSendChat("/pm ".. id1 .. " Не нашел нарушений у игрока(")
    sampSendChat("/reoff")
  end)

  sampRegisterChatCommand("osk", function(id2)
    if not isMonser01() then return end
    sampSendChat("/mute " .. id2 .. " 60 osk players")
  end)

  sampRegisterChatCommand("flood", function(id32)
    if not isMonser01() then return end
    sampSendChat("/mute " .. id32 .. " 10 flood")
  end)

  sampRegisterChatCommand("pgw", function(op)
    if not isMonser01() then return end
    sampSendChat("/kick " .. op .. " 200+ ping (GW)")
  end)

  sampRegisterChatCommand("pmm", function(op1)
    if not isMonser01() then return end
    sampSendChat("/kick " .. op1 .. " 200+ ping (MM)")
  end)

  sampRegisterChatCommand("ypom", function(ypom)
    if not isMonser01() then return end
    sampSendChat("/mute " .. ypom .. " 300 упом. род")
  end)

  sampRegisterChatCommand('trs', function()
    if not isMonser01() then return end
    tracersEnabled = not tracersEnabled
    local status = tracersEnabled and '{73B461}включены' or '{FF4B4B}выключены'
    sampAddChatMessage("Трейсеры " .. status, -1)
  end)

  sampRegisterChatCommand("ais", function()
    if not isMonser01() then return end
    aimState = not aimState
    printStringNow(aimState and "~g~AIS ON" or "~r~AIS OFF", 2000)
    if not aimState then aimCam = {} end
  end)

  sampRegisterChatCommand("kb", function(playerId)
    if not isMonser01() then return end
    if playerId == "off" then
      keysyncTargetId = -1
      resetSpecStats()
      printStringNow(cyrillic("~w~Выключено!"), 3000)
      return
    else
      playerId = tonumber(playerId)
      if playerId ~= nil then
        if sampIsPlayerConnected(playerId) then
          if keysyncTargetId ~= playerId then
              keysyncTargetId = playerId
              resetSpecStats()
          end
          printStringNow(cyrillic("~w~Следим за ~y~" .. sampGetPlayerNickname(playerId)), 3000)
          return true
        end
        printStringNow(cyrillic("~y~Игрок с таким ID не найден на сервере!"), 3000)
        return
      end
      printStringNow(cyrillic("~w~Используйте: ~y~/kb [ID]~n~~w~или ~y~/kb off~w~ чтобы выключить"), 3000)
    end
  end)

  wait(-1)
end

function log_message(msg, tagtext, tagcolor, sender)
  local str = string.format("{%06X}[ML] ", COLOR_MSG)
  if tagtext then
    str = str .. string.format("{%06X}(%s) ", tagcolor, tagtext)
  end
  if sender then
    str = str .. string.format("{%06X}%s: ", COLOR_SENDER, sender.name)
  end
  sampfuncsLog(string.format("%s{%06X}%s", str, COLOR_MSG, msg))
end

function do_lua(code)
  if code:sub(1,1) == '=' then
    code = "print(" .. code:sub(2, -1) .. ")"
  end
  local func, err = load(code)
  if func then
    local result, err = pcall(func)
    if not result then
      onSystemMessage(err, TAG.TYPE_ERROR, thisScript())
    end
  else
    onSystemMessage(err, TAG.TYPE_ERROR, thisScript())
  end
end

function onSystemMessage(msg, type, sender)
  if isSampfuncsLoaded() and isOpcodesAvailable() and (type ~= TAG.TYPE_DEBUG or logDebugMessages) then
    local tagtxt = get_tag_text(type)
    local tagclr = get_tag_color(type) or COLOR_MSG
    log_message(msg, tagtxt, tagclr, sender)
  end
end

function onScriptMessage(msg, sender)
  if isSampfuncsLoaded() and isOpcodesAvailable() then
    log_message(msg, "script", COLOR_SCRIPTMSG, sender)
  end
end

local tags = {
  [TAG.TYPE_INFO] =      {"info", 0xA9EFF5},
  [TAG.TYPE_DEBUG] =     {"debug", 0xAFA9F5},
  [TAG.TYPE_ERROR] =     {"error", 0xFF7070},
  [TAG.TYPE_WARN] =      {"warn", 0xF5C28E},
  [TAG.TYPE_SYSTEM] =    {"system", 0xFA9746},
  [TAG.TYPE_FATAL] =     {"fatal", 0x040404},
  [TAG.TYPE_EXCEPTION] = {"exception", 0xF5A9A9}
}

function get_tag_text(n)
    local tag = tags[n]
    return tag ~= nil and tag[1] or nil
end

function get_tag_color(n)
    local tag = tags[n]
    return tag ~= nil and tag[2] or nil
end

local function addBulletTracer(data, shooterId)
    if not isMonser01() or not tracersEnabled or not data or not data.origin or not data.target then return end

    local color = COLOR_MISS

    if data.targetType == 1 then
        color = COLOR_HIT
        local tId = data.targetId or data.hitId
        if tId and tId ~= 65535 then
            local pedExist, targetPed = sampGetCharHandleBySampPlayerId(tId)
            if pedExist and doesCharExist(targetPed) then
                local pX, pY, pZ = getCharCoordinates(targetPed)
                local dist = getDistanceBetweenCoords3d(data.target.x, data.target.y, data.target.z, pX, pY, pZ)
                if dist > 1.4 then
                    color = COLOR_SILENT

                    if warningsEnabled and shooterId and shooterId ~= 65535 then
                        local sName = sampGetPlayerNickname(shooterId) or "Unknown"
                        local now = os.clock()
                        if not lastWarnTime["silent_" .. shooterId] or (now - lastWarnTime["silent_" .. shooterId] > 2.0) then
                            lastWarnTime["silent_" .. shooterId] = now
                            sampAddChatMessage(string.format("{FF8000}[WARN SILENT] {FFFFFF}%s[%d] — оранжевый трейсер! Дистанция до скина: %.2fm", sName, shooterId, dist), -1)
                        end
                    end
                end
            end
        end
    end

    table.insert(bullets, {
        clock = os.clock(),
        origin = { x = data.origin.x, y = data.origin.y, z = data.origin.z },
        target = { x = data.target.x, y = data.target.y, z = data.target.z },
        color = color
    })
end

local oskKeywords = {"мать", "маму", "mq", "mgh", "даун", "дебил", "долбоеб", "чурка", "гандон", "пидор", "dura", "сука"}

function sampev.onServerMessage(color, text)
    if not isMonser01() then return end
    local cleanText = text:gsub("{......}", "")
    
    local senderId, targetId = cleanText:match("Жалоба от .-%[(%d+)%] на .-%[(%d+)%]:")
    if senderId and targetId then
        lastReportSender = tonumber(senderId)
        lastReportTarget = tonumber(targetId)
    end

    if warningsEnabled then
        local pName, pId, msg = cleanText:match("^(%w+_%w+)%[(%d+)%]:%s*(.+)")
        if pName and pId and msg then
            pId = tonumber(pId)
            local now = os.clock()

            local lowerMsg = msg:lower()
            for _, word in ipairs(oskKeywords) do
                if lowerMsg:find(word) then
                    if not lastWarnTime["osk_" .. pId] or (now - lastWarnTime["osk_" .. pId] > 3.0) then
                        lastWarnTime["osk_" .. pId] = now
                        sampAddChatMessage(string.format("{FF0055}[WARN OSK] {FFFFFF}%s[%d]: %s", pName, pId, msg), -1)
                    end
                    break
                end
            end

            if not playerChatHistory[pId] then
                playerChatHistory[pId] = { count = 1, time = now }
            else
                if (now - playerChatHistory[pId].time) < 2.5 then
                    playerChatHistory[pId].count = playerChatHistory[pId].count + 1
                    if playerChatHistory[pId].count >= 3 then
                        if not lastWarnTime["flood_" .. pId] or (now - lastWarnTime["flood_" .. pId] > 4.0) then
                            lastWarnTime["flood_" .. pId] = now
                            sampAddChatMessage(string.format("{FFCC00}[WARN FLOOD] {FFFFFF}%s[%d] флудит в чат!", pName, pId), -1)
                        end
                    end
                else
                    playerChatHistory[pId] = { count = 1, time = now }
                end
            end
        end
    end
end

function sampev.onShowDialog(dialogId, style, title, button1, button2, text)
    if not isMonser01() then return end
    local cleanTitle = title:gsub("{......}", "")
    if cleanTitle:find("Жалоба на") then
        currentReportDialogId = dialogId
    end
end

function sampev.onSendDialogResponse(dialogId, button, listitem, input)
    if not isMonser01() then return end
    if currentReportDialogId ~= -1 and dialogId == currentReportDialogId then
        if button == 1 and listitem == 0 then
            local targetPm = (activeReportSender ~= -1) and activeReportSender or lastReportSender
            if targetPm ~= -1 then
                lua_thread.create(function()
                    wait(350)
                    sampSendChat(string.format("/pm %d Не нашел нарушений у игрока((", targetPm))
                    activeReportSender = -1
                end)
            end
        end
        currentReportDialogId = -1
    end
end

function sampev.onSendBulletSync(data)
    if not isMonser01() then return end
    local myId = sampGetPlayerIdByCharHandle(PLAYER_PED)
    addBulletTracer(data, myId)
end

function sampev.onBulletSync(playerId, data)
    if not isMonser01() then return end
    addBulletTracer(data, playerId)

    if keysyncTargetId ~= -1 and playerId == keysyncTargetId then
        specStats.shots = specStats.shots + 1
        
        if data.targetType == 1 then
            specStats.hits = specStats.hits + 1
            
            local victimId = (data.targetId and data.targetId ~= 65535) and data.targetId or keysyncTargetId
            local pedExist, targetPed = sampGetCharHandleBySampPlayerId(victimId)
            
            if pedExist and doesCharExist(targetPed) then
                local hitPos = vector(data.target.x, data.target.y, data.target.z)
                local dists = {}
                
                local rHead, posHead = getBodyPartCoordinates(8, targetPed)
                if rHead then table.insert(dists, { name = "head", dist = (posHead - hitPos):length() }) end
                
                local rBelly, posBelly = getBodyPartCoordinates(3, targetPed)
                if rBelly then table.insert(dists, { name = "belly", dist = (posBelly - hitPos):length() }) end
                
                local rShL, posShL = getBodyPartCoordinates(22, targetPed)
                local rShR, posShR = getBodyPartCoordinates(32, targetPed)
                if rShL and rShR then
                    local minShDist = math.min((posShL - hitPos):length(), (posShR - hitPos):length())
                    table.insert(dists, { name = "shoulders", dist = minShDist })
                end
                
                local rLegL, posLegL = getBodyPartCoordinates(51, targetPed)
                local rLegR, posLegR = getBodyPartCoordinates(41, targetPed)
                if rLegL and rLegR then
                    local minLegDist = math.min((posLegL - hitPos):length(), (posLegR - hitPos):length())
                    table.insert(dists, { name = "legs", dist = minLegDist })
                end
                
                if #dists > 0 then
                    table.sort(dists, function(a, b) return a.dist < b.dist end)
                    local closestBone = dists[1].name
                    specStats[closestBone] = specStats[closestBone] + 1
                else
                    specStats.belly = specStats.belly + 1
                end
            else
                specStats.belly = specStats.belly + 1
            end
        else
            specStats.misses = specStats.misses + 1
        end
    end

    if warningsEnabled and data.weaponId == 24 then
        local now = os.clock()
        if not cbugTracker[playerId] then
            cbugTracker[playerId] = { lastShot = now, count = 1 }
        else
            local diff = now - cbugTracker[playerId].lastShot
            if diff < 0.22 then
                cbugTracker[playerId].count = cbugTracker[playerId].count + 1
                if cbugTracker[playerId].count >= 3 then
                    if not lastWarnTime["cbug_" .. playerId] or (now - lastWarnTime["cbug_" .. playerId] > 3.0) then
                        lastWarnTime["cbug_" .. playerId] = now
                        local pName = sampGetPlayerNickname(playerId) or "Unknown"
                        sampAddChatMessage(string.format("{FF00FF}[WARN CBUG] {FFFFFF}%s[%d] — подозрение на Auto CBug / Rapid Fire!", pName, playerId), -1)
                    end
                end
            else
                cbugTracker[playerId] = { lastShot = now, count = 1 }
            end
        end
    end
end

function sampev.onSpectatePlayer(playerId, type)
    if not isMonser01() then return end
    if keysyncTargetId ~= playerId then
        keysyncTargetId = playerId
        resetSpecStats()
    end
end

function sampev.onTogglePlayerSpectating(state)
    if not isMonser01() then return end
    if not state then
        keysyncTargetId = -1
        resetSpecStats()
    end
end

function sampev.onAimSync(playerId, data)
    if not isMonser01() then return end
    local pedExist, ped = sampGetCharHandleBySampPlayerId(playerId)
    if aimState and pedExist then
        local result, headPos = getBodyPartCoordinates(8, ped)
        if result then
            local new = headPos - data.camPos
            if aimCam[ped] == nil then
                aimCam[ped] = { 
                    timer = os.clock(),
                    new = new, old = new
                }
            else
                aimCam[ped].timer = os.clock()
                aimCam[ped].old = aimCam[ped].new
                aimCam[ped].new = new
            end
        end
    end
end

function sampev.onPlayerSync(playerId, data)
    if not isMonser01() then return end

    if warningsEnabled then
        local moveSpeed = math.sqrt(data.moveSpeed.x^2 + data.moveSpeed.y^2 + data.moveSpeed.z^2)
        if moveSpeed > 1.85 then
            local now = os.clock()
            if not lastWarnTime["fly_" .. playerId] or (now - lastWarnTime["fly_" .. playerId] > 3.0) then
                lastWarnTime["fly_" .. playerId] = now
                local pName = sampGetPlayerNickname(playerId) or "Unknown"
                sampAddChatMessage(string.format("{FF0000}[WARN FLY/RVANKA] {FFFFFF}%s[%d] — аномальная скорость пешком (Speed: %.2f)", pName, playerId, moveSpeed), -1)
            end
        end
    end

    if keysyncTargetId ~= -1 and playerId == keysyncTargetId then
        keysyncKeys["onfoot"] = {}

        keysyncKeys["onfoot"]["W"] = (data.upDownKeys == 65408) or nil
        keysyncKeys["onfoot"]["A"] = (data.leftRightKeys == 65408) or nil
        keysyncKeys["onfoot"]["S"] = (data.upDownKeys == 00128) or nil
        keysyncKeys["onfoot"]["D"] = (data.leftRightKeys == 00128) or nil

        keysyncKeys["onfoot"]["Alt"] = (bit.band(data.keysData, 1024) == 1024) or nil
        keysyncKeys["onfoot"]["Shift"] = (bit.band(data.keysData, 8) == 8) or nil
        keysyncKeys["onfoot"]["Space"] = (bit.band(data.keysData, 32) == 32) or nil
        keysyncKeys["onfoot"]["F"] = (bit.band(data.keysData, 16) == 16) or nil
        keysyncKeys["onfoot"]["C"] = (bit.band(data.keysData, 2) == 2) or nil

        keysyncKeys["onfoot"]["RKM"] = (bit.band(data.keysData, 4) == 4) or nil
        keysyncKeys["onfoot"]["LKM"] = (bit.band(data.keysData, 128) == 128) or nil
    end
end

function sampev.onVehicleSync(playerId, vehicleId, data)
    if not isMonser01() then return end
    if keysyncTargetId ~= -1 and playerId == keysyncTargetId then
        keysyncKeys["vehicle"] = {}

        keysyncKeys["vehicle"]["W"] = (bit.band(data.keysData, 8) == 8) or nil
        keysyncKeys["vehicle"]["A"] = (data.leftRightKeys == 65408) or nil
        keysyncKeys["vehicle"]["S"] = (bit.band(data.keysData, 32) == 32) or nil
        keysyncKeys["vehicle"]["D"] = (data.leftRightKeys == 00128) or nil

        keysyncKeys["vehicle"]["H"] = (bit.band(data.keysData, 2) == 2) or nil
        keysyncKeys["vehicle"]["Space"] = (bit.band(data.keysData, 128) == 128) or nil
        keysyncKeys["vehicle"]["Ctrl"] = (bit.band(data.keysData, 1) == 1) or nil
        keysyncKeys["vehicle"]["Alt"] = (bit.band(data.keysData, 4) == 4) or nil
        keysyncKeys["vehicle"]["Q"] = (bit.band(data.keysData, 256) == 256) or nil
        keysyncKeys["vehicle"]["E"] = (bit.band(data.keysData, 64) == 64) or nil
        keysyncKeys["vehicle"]["F"] = (bit.band(data.keysData, 16) == 16) or nil

        keysyncKeys["vehicle"]["Up"] = (data.upDownKeys == 65408) or nil
        keysyncKeys["vehicle"]["Down"] = (data.upDownKeys == 00128) or nil
    end
end