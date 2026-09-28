--[[
    FunnyHub loader v3 — multi-map key gate.
    Run from GitHub / worker:
        loadstring(game:HttpGet("https://keyhub.kaguyashinomiy.workers.dev/funnyhub.lua"))()

    Flow:
      - detect the current map by game.PlaceId from MANIFEST (below)
      - if the place is unknown, show a map picker before redeeming
      - redeem/auto-redeem the saved key -> auth the MAP's script_id
      - decrypt that map's payload (RC4 + watermark check) -> loadstring

    Multi-map rule: one project = one key = every map. The loader only ever
    auths and loads ONE script_id (the map you are in), so a map's functions
    can never leak into another map's session.
]]

local API_URL      = "https://keyhub.kaguyashinomiy.workers.dev"
local KEYPAGE_URL  = API_URL .. "/key"
local KEY_FILE     = "funnyhub.txt"
local LOADER_VERSION = "3.0.0"
local LOCAL_SEED   = "fhub_"  -- at-rest key obfuscation (not real crypto)

-- =====================================================================
--  MANIFEST  — map id -> { name, script_id, places }
--  Add a new map here AND create its script_id on KeyHub. The loader is
--  re-fetched fresh on every run, so editing this file updates every user.
-- =====================================================================
local MANIFEST = {
  {
    id = "finalboss",
    name = "Be The Final Boss",
    script_id = "904b956445aaeb8648039a0256a7f809",
    places = { 140302982046391 },
  },
  {
    id = "zombies",
    name = "Build and Kill Zombies",
    script_id = "aa07c6c94c47b891ed87f70c656d97cd",
    places = { 105011592530400 },
  },
}

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer

local function notify(text, seconds)
  pcall(function()
    game:GetService("StarterGui"):SetCore("SendNotification", { Title = "FunnyHub", Text = text, Duration = seconds or 5 })
  end)
  print("[FunnyHub] " .. tostring(text))
end

-- ===================================================================== encoding
local function fromHex(hex)
  return (hex:gsub("%x%x", function(byte) return string.char(tonumber(byte, 16)) end))
end
local function toHex(data)
  return (data:gsub(".", function(c) return string.format("%02x", string.byte(c)) end))
end
local function xorData(data, key)
  local out = {}
  for i = 1, #data do
    out[i] = string.char(bit32.bxor(string.byte(data, i), string.byte(key, (i - 1) % #key + 1)))
  end
  return table.concat(out)
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

-- ===================================================================== http
local function httpRequest(method, url, body, tries)
  tries = tries or 3
  local headers = { ["Content-Type"] = "application/json", ["User-Agent"] = "KeyHub/" .. LOADER_VERSION }
  for attempt = 1, tries do
    local ok, res
    if type(request) == "function" then
      ok, res = pcall(request, { Url = url, Method = method, Body = body, Headers = headers })
      if ok and res and res.Body and res.Body ~= "" then return res.Body end
    end
    local fallback = (syn and syn.request) or (http and http.request) or http_request
    if type(fallback) == "function" then
      ok, res = pcall(fallback, { Url = url, Method = method, Body = body, Headers = headers })
      if ok and res and res.Body and res.Body ~= "" then return res.Body end
    end
    ok, res = pcall(function()
      if method == "GET" then return HttpService:GetAsync(url) end
      return HttpService:PostAsync(url, body, Enum.HttpContentType.ApplicationJson, false)
    end)
    if ok and res and res ~= "" then return res end
    if attempt < tries then task.wait(0.5 * attempt) end
  end
  return nil
end

-- ===================================================================== hwid
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
local HWID = getHWID()

-- ===================================================================== probes
local function report(key, reason, detail)
  pcall(function()
    httpRequest("POST", API_URL .. "/api/v1/report", HttpService:JSONEncode({
      key = key or "", hwid = HWID, reason = reason, detail = tostring(detail or ""),
    }))
  end)
end

local function integrityFlags()
  local flags = {}
  local function isLuaFunction(fn)
    local ok, info = pcall(function() return debug and debug.getinfo and debug.getinfo(fn, "S") end)
    if ok and type(info) == "table" and info.what then return info.what ~= "C" end
    return false
  end
  if type(loadstring) == "function" and isLuaFunction(loadstring) then flags[#flags + 1] = "loadstring_hook" end
  if type(load) == "function" and isLuaFunction(load) then flags[#flags + 1] = "load_hook" end
  if type(print) == "function" and isLuaFunction(print) then flags[#flags + 1] = "print_hook" end
  if type(getrawmetatable) == "function" then
    local ok, mt = pcall(getrawmetatable, game)
    if not ok or type(mt) ~= "table" or type(mt.__namecall) ~= "function" then
      flags[#flags + 1] = "namecall_spoof"
    end
  end
  if type(getgenv) == "function" then
    local ok, g = pcall(getgenv)
    if ok and type(g) == "table" and type(g.FunnyHub) == "table" and g.FunnyHub.verified then
      flags[#flags + 1] = "reentry"
    end
  end
  local ok, ident = pcall(function() return identifyexecutor and identifyexecutor() end)
  if ok and ident then flags[#flags + 1] = "executor=" .. tostring(ident) end
  return flags
end

-- ===================================================================== auth
local function authenticate(scriptId, key)
  if HWID == "" then return { code = "NO_HWID", message = "Could not read HWID" } end
  local body = HttpService:JSONEncode({ key = key, hwid = HWID, script_id = scriptId })
  local raw = httpRequest("POST", API_URL .. "/api/v1/auth", body)
  if raw == nil then return { code = "NETWORK", message = "Server unreachable" } end
  local ok, response = pcall(function() return HttpService:JSONDecode(raw) end)
  if not ok or type(response) ~= "table" then return { code = "BAD_RESPONSE", message = "Server error" } end
  return response
end

-- ===================================================================== cache
local function cacheFile(scriptId) return "funnyhub_" .. tostring(scriptId) .. "_cache.txt" end
local function saveCache(scriptId, response)
  if not response or not response.payload then return end
  pcall(function()
    if writefile then
      writefile(cacheFile(scriptId), HttpService:JSONEncode({
        payload = response.payload, nonce = response.nonce, wm = response.wm,
        script_version = response.script_version,
        expires_at = os.time() + (tonumber(response.seconds_left) or 0),
      }))
    end
  end)
end
local function loadCache(scriptId)
  local ok, data = pcall(function()
    if isfile and isfile(cacheFile(scriptId)) then return readfile(cacheFile(scriptId)) end
    return nil
  end)
  if not ok or type(data) ~= "string" then return nil end
  local ok2, cached = pcall(function() return HttpService:JSONDecode(data) end)
  if not ok2 or type(cached) ~= "table" then return nil end
  if (cached.expires_at or 0) <= os.time() then return nil end
  return cached
end

-- ===================================================================== run
local function runScript(scriptId, response, key)
  local cipher = fromHex(response.payload)
  local plain = rc4(response.nonce .. scriptId, cipher)

  if response.wm and response.wm ~= "" then
    if not string.find(plain, "uid=" .. tostring(response.wm) .. " ", 1, true) then
      report(key, "payload_replay", "watermark mismatch for uid " .. tostring(response.wm))
      notify("This build is licensed to another user. Please get your own key.")
      return
    end
  end

  for _, flag in ipairs(integrityFlags()) do report(key, flag, "loader integrity probe") end

  local genv = (type(getgenv) == "function") and getgenv() or _G
  genv.FunnyHub = {
    verified = true, key = key, hwid = HWID, script_id = scriptId,
    api_url = API_URL, script_version = response.script_version,
    seconds_left = response.seconds_left, at = os.time(),
  }

  saveCache(scriptId, response)

  local chunk, err = loadstring(plain)
  if not chunk then notify("Failed to load: " .. tostring(err)); return end

  local left = tonumber(response.seconds_left) or -1
  local suffix = left and left > 0 and string.format(" · %.1fh left", left / 3600) or ""
  notify(string.format("Authenticated (v%s)%s. Loading…", tostring(response.script_version or "?"), suffix))
  chunk()
end

-- ===================================================================== key file
local function readSavedKey()
  local ok, data = pcall(function()
    if isfile and isfile(KEY_FILE) then return readfile(KEY_FILE) end
    return nil
  end)
  if not ok or type(data) ~= "string" or data == "" then return "" end
  data = (data:gsub("%s+$", ""))
  -- New format is XOR+hex. Hex is [0-9a-f], which ALSO matches an alphanumeric
  -- test, so decode hex FIRST (even length, pure hex) and only accept the result
  -- when it looks like a key. Otherwise treat it as a legacy plaintext key, so
  -- switching loaders never bricks a saved key.
  if #data >= 16 and #data % 2 == 0 and data:match("^%x+$") then
    local dec = (xorData(fromHex(data), LOCAL_SEED):gsub("%s+$", ""))
    if #dec >= 16 and dec:match("^[%w_%-]+$") then return dec end
  end
  if #data >= 16 and data:match("^[%w_%-]+$") then return data end
  return data
end
local function saveKey(key)
  pcall(function() if writefile then writefile(KEY_FILE, toHex(xorData(key, LOCAL_SEED))) end end)
end

-- ===================================================================== map pick
local function detectMap()
  local pid = tostring(game.PlaceId)
  for _, m in ipairs(MANIFEST) do
    for _, p in ipairs(m.places or {}) do
      if tostring(p) == pid then return m end
    end
  end
  return nil
end

-- ===================================================================== GUI
local function showGUI(prefill, statusText, statusColor, detectedMap)
  local gui = Instance.new("ScreenGui")
  gui.Name = "KeyHubUI"
  gui.ResetOnSpawn = false
  pcall(function() gui.Parent = gethui and gethui() or game:GetService("CoreGui") end)
  if not gui.Parent then gui.Parent = LocalPlayer:WaitForChild("PlayerGui") end

  local selectedMap = detectedMap
  local height = detectedMap and 180 or 250

  local frame = Instance.new("Frame")
  frame.Size = UDim2.new(0, 340, 0, height)
  frame.Position = UDim2.new(0.5, -170, 0.5, -height / 2)
  frame.BackgroundColor3 = Color3.fromRGB(22, 26, 36)
  frame.BorderSizePixel = 0
  frame.Active = true
  frame.Draggable = true
  frame.Parent = gui
  local corner = Instance.new("UICorner"); corner.CornerRadius = UDim.new(0, 12); corner.Parent = frame

  local title = Instance.new("TextLabel")
  title.Size = UDim2.new(1, -36, 0, 40)
  title.BackgroundColor3 = Color3.fromRGB(99, 102, 241)
  title.Text = "FunnyHub — Key System"
  title.TextColor3 = Color3.new(1, 1, 1)
  title.Font = Enum.Font.GothamBold
  title.TextSize = 15
  title.Parent = frame
  local tcorner = Instance.new("UICorner"); tcorner.CornerRadius = UDim.new(0, 12); tcorner.Parent = title

  local close = Instance.new("TextButton")
  close.Size = UDim2.new(0, 36, 0, 40)
  close.Position = UDim2.new(1, -36, 0, 0)
  close.BackgroundColor3 = Color3.fromRGB(239, 68, 68)
  close.Text = "✕"
  close.TextColor3 = Color3.new(1, 1, 1)
  close.Font = Enum.Font.GothamBold
  close.TextSize = 16
  close.Parent = frame
  local ccorner = Instance.new("UICorner"); ccorner.CornerRadius = UDim.new(0, 12); ccorner.Parent = close
  close.MouseButton1Click:Connect(function() gui:Destroy() end)

  local y = 52

  -- map picker (only when the current place isn't a known map)
  if not detectedMap then
    local mapLabel = Instance.new("TextLabel")
    mapLabel.Size = UDim2.new(1, -30, 0, 18)
    mapLabel.Position = UDim2.new(0, 15, 0, y)
    mapLabel.BackgroundTransparency = 1
    mapLabel.Text = "Pick the map you're in:"
    mapLabel.TextColor3 = Color3.fromRGB(139, 147, 167)
    mapLabel.Font = Enum.Font.Gotham
    mapLabel.TextSize = 12
    mapLabel.TextXAlignment = Enum.TextXAlignment.Left
    mapLabel.Parent = frame
    y = y + 22

    local mapList = Instance.new("ScrollingFrame")
    mapList.Size = UDim2.new(1, -30, 0, 56)
    mapList.Position = UDim2.new(0, 15, 0, y)
    mapList.BackgroundColor3 = Color3.fromRGB(15, 17, 23)
    mapList.BorderSizePixel = 0
    mapList.ScrollBarThickness = 4
    mapList.CanvasSize = UDim2.new(0, 0, 0, 28 * #MANIFEST)
    mapList.Parent = frame
    local mcorner = Instance.new("UICorner"); mcorner.CornerRadius = UDim.new(0, 8); mcorner.Parent = mapList

    local mapButtons = {}
    for i, m in ipairs(MANIFEST) do
      local btn = Instance.new("TextButton")
      btn.Size = UDim2.new(1, -8, 0, 24)
      btn.Position = UDim2.new(0, 4, 0, (i - 1) * 26)
      btn.BackgroundColor3 = Color3.fromRGB(30, 35, 48)
      btn.Text = m.name
      btn.TextColor3 = Color3.new(1, 1, 1)
      btn.Font = Enum.Font.Gotham
      btn.TextSize = 12
      btn.Parent = mapList
      btn.MouseButton1Click:Connect(function()
        selectedMap = m
        for _, b in ipairs(mapButtons) do b.BackgroundColor3 = Color3.fromRGB(30, 35, 48) end
        btn.BackgroundColor3 = Color3.fromRGB(99, 102, 241)
      end)
      mapButtons[#mapButtons + 1] = btn
    end
    y = y + 62
  end

  local box = Instance.new("TextBox")
  box.Size = UDim2.new(1, -30, 0, 34)
  box.Position = UDim2.new(0, 15, 0, y)
  box.BackgroundColor3 = Color3.fromRGB(15, 17, 23)
  box.TextColor3 = Color3.new(1, 1, 1)
  box.PlaceholderText = "Paste your key here"
  box.Text = prefill or ""
  box.Font = Enum.Font.Code
  box.TextSize = 13
  box.ClearTextOnFocus = true  -- tapping the box clears the saved-key prefill so a paste cannot stack
  box.Parent = frame
  local bcorner = Instance.new("UICorner"); bcorner.CornerRadius = UDim.new(0, 8); bcorner.Parent = box

  local redeem = Instance.new("TextButton")
  redeem.Size = UDim2.new(0.5, -20, 0, 36)
  redeem.Position = UDim2.new(0, 15, 0, y + 44)
  redeem.BackgroundColor3 = Color3.fromRGB(34, 197, 94)
  redeem.Text = "REDEEM KEY"
  redeem.TextColor3 = Color3.fromRGB(4, 18, 10)
  redeem.Font = Enum.Font.GothamBold
  redeem.TextSize = 13
  redeem.Parent = frame
  local rcorner = Instance.new("UICorner"); rcorner.CornerRadius = UDim.new(0, 8); rcorner.Parent = redeem

  local getkey = Instance.new("TextButton")
  getkey.Size = UDim2.new(0.5, -20, 0, 36)
  getkey.Position = UDim2.new(0.5, 5, 0, y + 44)
  getkey.BackgroundColor3 = Color3.fromRGB(30, 35, 48)
  getkey.Text = "GET KEY"
  getkey.TextColor3 = Color3.fromRGB(99, 102, 241)
  getkey.Font = Enum.Font.GothamBold
  getkey.TextSize = 13
  getkey.Parent = frame
  local gcorner = Instance.new("UICorner"); gcorner.CornerRadius = UDim.new(0, 8); gcorner.Parent = getkey

  local status = Instance.new("TextLabel")
  status.Size = UDim2.new(1, -30, 0, 30)
  status.Position = UDim2.new(0, 15, 0, y + 86)
  status.BackgroundTransparency = 1
  status.Text = statusText or "Enter a key or press GET KEY"
  status.TextColor3 = statusColor or Color3.fromRGB(139, 147, 167)
  status.Font = Enum.Font.Gotham
  status.TextSize = 12
  status.TextWrapped = true
  status.TextXAlignment = Enum.TextXAlignment.Left
  status.Parent = frame

  local function setStatus(text, color)
    status.Text = text
    status.TextColor3 = color or Color3.fromRGB(139, 147, 167)
  end
  local function setBusy(state)
    redeem.Text = state and "Checking…" or "REDEEM KEY"
    redeem.Interactable = not state
    box.Interactable = not state
  end

  getkey.MouseButton1Click:Connect(function()
    local link, auto = KEYPAGE_URL, false
    pcall(function()
      local raw = httpRequest("POST", API_URL .. "/api/v1/ad/session", HttpService:JSONEncode({ provider = "" }))
      if raw then
        local data = HttpService:JSONDecode(raw)
        if type(data) == "table" and data.success and data.token then
          link, auto = KEYPAGE_URL .. "?t=" .. tostring(data.token) .. "&a=1", true
        end
      end
    end)
    pcall(function() setclipboard(link) end)
    setStatus(auto and "Link copied — it opens the task by itself" or ("Link copied: " .. KEYPAGE_URL), Color3.fromRGB(99, 102, 241))
    notify(auto and "Key link copied — open it, finish the task, then copy your key."
              or "Key page link copied — open it, complete the tasks, then paste the key here.")
  end)

  redeem.MouseButton1Click:Connect(function()
    local key = (box.Text or ""):gsub("%s", "")
    if key == "" then setStatus("Paste a key first", Color3.fromRGB(248, 113, 113)); return end
    if not selectedMap then setStatus("Pick a map first", Color3.fromRGB(248, 113, 113)); return end
    setBusy(true)
    setStatus("Checking…")
    task.spawn(function()
      local response = authenticate(selectedMap.script_id, key)
      if response.success then
        saveKey(key)
        setStatus("Valid! Loading…", Color3.fromRGB(34, 197, 94))
        task.wait(0.4)
        gui:Destroy()
        runScript(selectedMap.script_id, response, key)
      elseif response.code == "NETWORK" then
        setBusy(false)
        setStatus("Server unreachable — try again", Color3.fromRGB(248, 113, 113))
      elseif response.code == "KEY_HWID_LOCKED" then
        setBusy(false)
        setStatus("Key locked to another HWID. Reset it.", Color3.fromRGB(248, 113, 113))
      elseif response.code == "KEY_EXPIRED" then
        setBusy(false)
        setStatus("Key expired — please get a new key.", Color3.fromRGB(248, 113, 113))
      else
        setBusy(false)
        setStatus("Invalid key — please get a key.", Color3.fromRGB(248, 113, 113))
      end
    end)
  end)
end

-- ===================================================================== boot
task.spawn(function()
  local map = detectMap()
  local saved = readSavedKey()
  if saved ~= "" and map then
    local response = authenticate(map.script_id, saved)
    if response.success then
      runScript(map.script_id, response, saved)
      return
    end
    if response.code == "NETWORK" or response.code == "BAD_RESPONSE" then
      local cached = loadCache(map.script_id)
      if cached then
        notify("Server unreachable — using cached build", 6)
        runScript(map.script_id, cached, saved)
        return
      end
    end
    local why = response.code == "KEY_EXPIRED"
      and "Key expired — please get a new key."
      or "Saved key is invalid — please get a new key."
    showGUI(saved, why, Color3.fromRGB(248, 113, 113), map)
    return
  end
  if not map then notify("This game isn't mapped yet — pick a map in the menu.", 6) end
  showGUI(saved, map and "Enter a key or press GET KEY" or "Pick a map, then enter a key.", nil, map)
end)
