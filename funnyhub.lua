--[[
    FunnyHub client — key gate + Get Key / Redeem GUI.

    Run it from GitHub (or anywhere):
        loadstring(game:HttpGet("https://raw.githubusercontent.com/YOU/REPO/main/funnyhub.lua"))()

    Flow:
      - tries the saved key first (auto-redeem on rejoin)
      - if missing / expired it shows a small GUI:
            [ GET KEY ]    -> copies the key page link
            [ REDEEM ]     -> validates + saves + loads the farm
      - a valid key is remembered in funnyhub.txt and reused next time
]]

local API_URL    = "http://127.0.0.1:8790"  -- <- change to https://your-domain for release
local SCRIPT_ID  = "ee87bbab00ca1fc208e7edd5930e4d5f"
local KEYPAGE_URL = API_URL .. "/key"
local KEY_FILE   = "funnyhub.txt"

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer

local function notify(text, seconds)
    pcall(function()
        game:GetService("StarterGui"):SetCore("SendNotification", { Title = "FunnyHub", Text = text, Duration = seconds or 5 })
    end)
    print("[FunnyHub] " .. tostring(text))
end

local function httpRequest(method, url, body)
    local headers = { ["Content-Type"] = "application/json", ["User-Agent"] = "KeyHub" }
    if type(request) == "function" then
        local ok, res = pcall(request, { Url = url, Method = method, Body = body, Headers = headers })
        if ok and res and res.Body then return res.Body end
    end
    local fallback = (syn and syn.request) or (http and http.request) or http_request
    if type(fallback) == "function" then
        local ok, res = pcall(fallback, { Url = url, Method = method, Body = body, Headers = headers })
        if ok and res and res.Body then return res.Body end
    end
    if method == "GET" then return game:HttpGet(url, true) end
    return game:HttpPost(url, body, "application/json", true)
end

local function getHWID()
    local getters = {
        function() return gethwid and gethwid() end,
        function() return get_hwid and get_hwid() end,
        function() return syn and syn.get_hwid and syn.get_hwid() end,
        function() return Krnl and Krnl.GetHWID and Krnl.GetHWID() end,
        function() return game:GetService("RbxAnalyticsService"):GetClientId() end,
    }
    for _, fn in ipairs(getters) do
        local ok, value = pcall(fn)
        if ok and type(value) == "string" and #value > 0 then return value end
    end
    return ""
end

local function fromHex(hex)
    return (hex:gsub("%x%x", function(byte) return string.char(tonumber(byte, 16)) end))
end

local function rc4(key, data)
    local s = {}
    for i = 0, 255 do s[i] = i end
    local j = 0
    for i = 0, 255 do
        j = (j + s[i] + string.byte(key, (i % #key) + 1)) % 256
        s[i], s[j] = s[j], s[i]
    end
    local out = {}
    local a, b = 0, 0
    for p = 1, #data do
        a = (a + 1) % 256
        b = (b + s[a]) % 256
        s[a], s[b] = s[b], s[a]
        out[p] = string.char(bit32.bxor(string.byte(data, p), s[(s[a] + s[b]) % 256]))
    end
    return table.concat(out)
end

local HWID = getHWID()

local function authenticate(key)
    if HWID == "" then return { code = "NO_HWID", message = "Could not read HWID" } end
    local body = HttpService:JSONEncode({ key = key, hwid = HWID, script_id = SCRIPT_ID })
    local raw = httpRequest("POST", API_URL .. "/api/v1/auth", body)
    local ok, response = pcall(function() return HttpService:JSONDecode(raw) end)
    if not ok or type(response) ~= "table" then return { code = "BAD_RESPONSE", message = "Server error" } end
    return response
end

local function runScript(response)
    local cipher = fromHex(response.payload)
    local plain = rc4(response.nonce .. SCRIPT_ID, cipher)
    local chunk, err = loadstring(plain)
    if not chunk then notify("Failed to load: " .. tostring(err)); return end
    notify("Authenticated. Loading script…")
    chunk()
end

-- ------------------------------------------------------------------ GUI

local function readSavedKey()
    local ok, data = pcall(function()
        if isfile and isfile(KEY_FILE) then return readfile(KEY_FILE) end
        return nil
    end)
    if ok and type(data) == "string" then return (data:gsub("%s+$", "")) end
    return ""
end

local function saveKey(key)
    pcall(function() if writefile then writefile(KEY_FILE, key) end end)
end

local function showGUI(prefill, statusText, statusColor)
    local gui = Instance.new("ScreenGui")
    gui.Name = "KeyHubUI"
    gui.ResetOnSpawn = false
    pcall(function() gui.Parent = gethui and gethui() or game:GetService("CoreGui") end)
    if not gui.Parent then gui.Parent = LocalPlayer:WaitForChild("PlayerGui") end

    local frame = Instance.new("Frame")
    frame.Size = UDim2.new(0, 340, 0, 180)
    frame.Position = UDim2.new(0.5, -170, 0.5, -90)
    frame.BackgroundColor3 = Color3.fromRGB(22, 26, 36)
    frame.BorderSizePixel = 0
    frame.Active = true
    frame.Draggable = true
    frame.Parent = gui
    local corner = Instance.new("UICorner"); corner.CornerRadius = UDim.new(0, 12); corner.Parent = frame

    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, 0, 0, 40)
    title.BackgroundColor3 = Color3.fromRGB(99, 102, 241)
    title.Text = "FunnyHub — Key System"
    title.TextColor3 = Color3.new(1, 1, 1)
    title.Font = Enum.Font.GothamBold
    title.TextSize = 15
    title.Parent = frame
    local tcorner = Instance.new("UICorner"); tcorner.CornerRadius = UDim.new(0, 12); tcorner.Parent = title

    local box = Instance.new("TextBox")
    box.Size = UDim2.new(1, -30, 0, 34)
    box.Position = UDim2.new(0, 15, 0, 52)
    box.BackgroundColor3 = Color3.fromRGB(15, 17, 23)
    box.TextColor3 = Color3.new(1, 1, 1)
    box.PlaceholderText = "Paste your key here"
    box.Text = prefill or ""
    box.Font = Enum.Font.Code
    box.TextSize = 13
    box.ClearTextOnFocus = false
    box.Parent = frame
    local bcorner = Instance.new("UICorner"); bcorner.CornerRadius = UDim.new(0, 8); bcorner.Parent = box

    local redeem = Instance.new("TextButton")
    redeem.Size = UDim2.new(0.5, -20, 0, 36)
    redeem.Position = UDim2.new(0, 15, 0, 96)
    redeem.BackgroundColor3 = Color3.fromRGB(34, 197, 94)
    redeem.Text = "REDEEM KEY"
    redeem.TextColor3 = Color3.fromRGB(4, 18, 10)
    redeem.Font = Enum.Font.GothamBold
    redeem.TextSize = 13
    redeem.Parent = frame
    local rcorner = Instance.new("UICorner"); rcorner.CornerRadius = UDim.new(0, 8); rcorner.Parent = redeem

    local getkey = Instance.new("TextButton")
    getkey.Size = UDim2.new(0.5, -20, 0, 36)
    getkey.Position = UDim2.new(0.5, 5, 0, 96)
    getkey.BackgroundColor3 = Color3.fromRGB(30, 35, 48)
    getkey.Text = "GET KEY"
    getkey.TextColor3 = Color3.fromRGB(99, 102, 241)
    getkey.Font = Enum.Font.GothamBold
    getkey.TextSize = 13
    getkey.Parent = frame
    local gcorner = Instance.new("UICorner"); gcorner.CornerRadius = UDim.new(0, 8); gcorner.Parent = getkey

    local status = Instance.new("TextLabel")
    status.Size = UDim2.new(1, -30, 0, 30)
    status.Position = UDim2.new(0, 15, 0, 140)
    status.BackgroundTransparency = 1
    status.Text = statusText or "Enter a key or press GET KEY"
    status.TextColor3 = statusColor or Color3.fromRGB(139, 147, 167)
    status.Font = Enum.Font.Gotham
    status.TextSize = 12
    status.TextWrapped = true
    status.TextXAlignment = Enum.TextXAlignment.Left
    status.Parent = frame

    getkey.MouseButton1Click:Connect(function()
        pcall(function() setclipboard(KEYPAGE_URL) end)
        status.Text = "Link copied: " .. KEYPAGE_URL
        status.TextColor3 = Color3.fromRGB(99, 102, 241)
        notify("Key page link copied — open it, complete the tasks, then paste the key here.")
    end)

    redeem.MouseButton1Click:Connect(function()
        local key = (box.Text or ""):gsub("%s", "")
        if key == "" then status.Text = "Paste a key first"; return end
        status.Text = "Checking…"; status.TextColor3 = Color3.fromRGB(139, 147, 167)
        local response = authenticate(key)
        if response.success then
            saveKey(key)
            status.Text = "Valid! Loading…"; status.TextColor3 = Color3.fromRGB(34, 197, 94)
            task.wait(0.4)
            gui:Destroy()
            runScript(response)
        elseif response.code == "KEY_HWID_LOCKED" then
            status.Text = "Key locked to another HWID. Reset it."
            status.TextColor3 = Color3.fromRGB(248, 113, 113)
        elseif response.code == "KEY_EXPIRED" then
            status.Text = "Key expired — please get a new key."
            status.TextColor3 = Color3.fromRGB(248, 113, 113)
        else
            status.Text = "Invalid key — please get a key."
            status.TextColor3 = Color3.fromRGB(248, 113, 113)
        end
    end)
end

-- ------------------------------------------------------------------ boot

task.spawn(function()
    local saved = readSavedKey()
    if saved ~= "" then
        local response = authenticate(saved)
        if response.success then
            runScript(response)
            return
        end
        local why = response.code == "KEY_EXPIRED" and "Key expired — please get a new key." or "Saved key is invalid — please get a new key."
        showGUI(saved, why, Color3.fromRGB(248, 113, 113))
        return
    end
    showGUI("", "No key found. Press GET KEY.", nil)
end)
