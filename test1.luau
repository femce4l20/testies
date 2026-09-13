--[[
    Recursive Roblox Server Hopper / Reinjector

    REQUIRED:
        Set SCRIPT_URL to the raw URL containing THIS script.

    CONFIG:
        AUTO_REJOIN       = true
        REJOIN_SAME_SERVER = false
        recursive_execution = true

    Behavior:
        - Records the current JobId.
        - Fetches public servers for the current place.
        - Never selects a JobId already recorded.
        - Never selects the current JobId when REJOIN_SAME_SERVER = false.
        - Queues this script to execute automatically after teleport.
        - Repeats until no unvisited public servers remain.
        - When exhausted, destroys every BasePart in Workspace/game
          and displays "done."

    NOTE:
        queue_on_teleport / syn.queue_on_teleport / fluxus.queue_on_teleport
        are executor APIs and are NOT normal Roblox LocalScript APIs.
]]

--//==============================================================
--// CONFIG
--//==============================================================

local AUTO_REJOIN = true
local REJOIN_SAME_SERVER = false

-- Set this to true to continue hopping/reinjecting repeatedly.
local recursive_execution = true

-- Raw URL containing THIS exact script.
local SCRIPT_URL = "https://raw.githubusercontent.com/femce4l20/testies/refs/heads/main/test1.luau"

-- Number of server-list pages to inspect.
local MAX_SERVER_PAGES = 100

-- Small delay before looking for servers.
local INITIAL_DELAY = 1.5

-- Delay before teleporting.
local TELEPORT_DELAY = 0.5

-- TeleportSetting key used to persist visited JobIds.
local VISITED_SETTING = "RecursiveServerHop_Visited_v1"

--//==============================================================
--// SERVICES
--//==============================================================

local Players = game:GetService("Players")
local TeleportService = game:GetService("TeleportService")
local HttpService = game:GetService("HttpService")

local LocalPlayer = Players.LocalPlayer

--//==============================================================
--// EXECUTOR COMPATIBILITY
--//==============================================================

local queueTeleport =
    queue_on_teleport
    or (syn and syn.queue_on_teleport)
    or (fluxus and fluxus.queue_on_teleport)

local httpGet =
    (function()
        if game.HttpGet then
            return function(url)
                return game:HttpGet(url)
            end
        end

        if request then
            return function(url)
                local response = request({
                    Url = url,
                    Method = "GET"
                })

                if response and response.Body then
                    return response.Body
                end

                error("request() returned no response body")
            end
        end

        error("No executor HTTP function is available.")
    end)()

--//==============================================================
--// BASIC VALIDATION
--//==============================================================

if not AUTO_REJOIN then
    warn("[RecursiveHop] AUTO_REJOIN is false. Stopping.")
    return
end

if SCRIPT_URL == "" or SCRIPT_URL:find("YOUR%-RAW%-SCRIPT%-URL") then
    warn("[RecursiveHop] Configure SCRIPT_URL before using recursive execution.")
    return
end

if recursive_execution and not queueTeleport then
    warn("[RecursiveHop] No queue_on_teleport-compatible executor function found.")
    warn("[RecursiveHop] Supported examples: queue_on_teleport, syn.queue_on_teleport, fluxus.queue_on_teleport")
    return
end

--//==============================================================
--// PERSISTENT VISITED SERVER STATE
--//==============================================================

local visited = {}

local function loadVisited()
    local saved = TeleportService:GetTeleportSetting(VISITED_SETTING)

    if typeof(saved) == "table" then
        for jobId, value in pairs(saved) do
            if value then
                visited[tostring(jobId)] = true
            end
        end
    elseif typeof(saved) == "string" then
        local ok, decoded = pcall(function()
            return HttpService:JSONDecode(saved)
        end)

        if ok and typeof(decoded) == "table" then
            for jobId, value in pairs(decoded) do
                if value then
                    visited[tostring(jobId)] = true
                end
            end
        end
    end
end

local function saveVisited()
    -- Roblox teleport settings support string-keyed tables.
    local copy = {}

    for jobId, value in pairs(visited) do
        if value then
            copy[tostring(jobId)] = true
        end
    end

    local ok, err = pcall(function()
        TeleportService:SetTeleportSetting(VISITED_SETTING, copy)
    end)

    if not ok then
        warn("[RecursiveHop] Failed to save visited server list:", err)

        -- Fallback to JSON string.
        pcall(function()
            TeleportService:SetTeleportSetting(
                VISITED_SETTING,
                HttpService:JSONEncode(copy)
            )
        end)
    end
end

loadVisited()

--//==============================================================
--// CURRENT SERVER
--//==============================================================

local currentJobId = tostring(game.JobId)

if currentJobId ~= "" then
    visited[currentJobId] = true
    saveVisited()

    print("[RecursiveHop] Current server:", currentJobId)
else
    warn("[RecursiveHop] Current JobId is empty.")
end

--//==============================================================
--// TELEPORT QUEUE
--//==============================================================

local function queueSelf()
    if not queueTeleport then
        return false
    end

    -- Execute this same hosted script after the teleport.
    local queuedCode = string.format([[
        task.wait(1.5)

        local success, err = pcall(function()
            loadstring(game:HttpGet(%q))()
        end)

        if not success then
            warn("[RecursiveHop] Failed to reinject:", err)
        end
    ]], SCRIPT_URL)

    local ok, err = pcall(function()
        queueTeleport(queuedCode)
    end)

    if not ok then
        warn("[RecursiveHop] Failed to queue teleport script:", err)
        return false
    end

    print("[RecursiveHop] Script queued for next server.")
    return true
end

--//==============================================================
--// SERVER API
--//==============================================================

local function fetchServers()
    local servers = {}
    local cursor = nil

    for page = 1, MAX_SERVER_PAGES do
        local url =
            ("https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=Asc&limit=100"):format(
                game.PlaceId
            )

        if cursor and cursor ~= "" then
            url = url .. "&cursor=" .. HttpService:UrlEncode(cursor)
        end

        local body

        local ok, err = pcall(function()
            body = httpGet(url)
        end)

        if not ok then
            warn("[RecursiveHop] Server API request failed:", err)
            break
        end

        local data

        ok, err = pcall(function()
            data = HttpService:JSONDecode(body)
        end)

        if not ok or typeof(data) ~= "table" then
            warn("[RecursiveHop] Invalid server API response.")
            break
        end

        if typeof(data.data) == "table" then
            for _, server in ipairs(data.data) do
                if server.id then
                    table.insert(servers, server)
                end
            end
        end

        cursor = data.nextPageCursor

        if not cursor or cursor == "" then
            break
        end
    end

    return servers
end

--//==============================================================
--// SELECT UNVISITED SERVER
--//==============================================================

local function chooseServer()
    local servers = fetchServers()

    print("[RecursiveHop] Servers discovered:", #servers)
    print("[RecursiveHop] Visited servers:", table.getn and "tracked" or "")

    local candidates = {}

    for _, server in ipairs(servers) do
        local jobId = tostring(server.id)

        local isCurrent = jobId == currentJobId
        local alreadyVisited = visited[jobId] == true

        local canUse =
            not alreadyVisited
            and (
                REJOIN_SAME_SERVER
                or not isCurrent
            )

        -- Prefer servers that aren't full.
        if canUse then
            local playing = tonumber(server.playing) or 0
            local maxPlayers = tonumber(server.maxPlayers) or 0

            if maxPlayers <= 0 or playing < maxPlayers then
                table.insert(candidates, server)
            end
        end
    end

    -- No normal candidates: perform a second pass that ignores player count,
    -- but still respects visited/current-server rules.
    if #candidates == 0 then
        for _, server in ipairs(servers) do
            local jobId = tostring(server.id)

            local isCurrent = jobId == currentJobId
            local alreadyVisited = visited[jobId] == true

            if not alreadyVisited and (REJOIN_SAME_SERVER or not isCurrent) then
                table.insert(candidates, server)
            end
        end
    end

    if #candidates == 0 then
        return nil
    end

    -- Pick randomly from the remaining unvisited servers.
    local selected = candidates[math.random(1, #candidates)]

    return selected
end

--//==============================================================
--// DONE UI
--//==============================================================

local function showDone()
    local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")

    if not playerGui then
        warn("[RecursiveHop] PlayerGui not available.")
        return
    end

    local old = playerGui:FindFirstChild("RecursiveHopDone")

    if old then
        old:Destroy()
    end

    local gui = Instance.new("ScreenGui")
    gui.Name = "RecursiveHopDone"
    gui.ResetOnSpawn = false
    gui.IgnoreGuiInset = true
    gui.DisplayOrder = 999999

    local background = Instance.new("Frame")
    background.Size = UDim2.fromScale(1, 1)
    background.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
    background.BackgroundTransparency = 0.15
    background.BorderSizePixel = 0
    background.Parent = gui

    local label = Instance.new("TextLabel")
    label.AnchorPoint = Vector2.new(0.5, 0.5)
    label.Position = UDim2.fromScale(0.5, 0.5)
    label.Size = UDim2.fromScale(0.8, 0.2)

    label.BackgroundTransparency = 1

    label.Text = "done."
    label.TextColor3 = Color3.fromRGB(255, 255, 255)
    label.TextScaled = true
    label.Font = Enum.Font.GothamBold

    label.Parent = background
    gui.Parent = playerGui
end

--//==============================================================
--// DESTROY ALL PARTS
--//==============================================================

local function destroyEveryPart()
    local destroyed = 0

    -- Snapshot first so destruction does not interfere with iteration.
    local descendants = game:GetDescendants()

    for _, instance in ipairs(descendants) do
        if instance:IsA("BasePart") then
            pcall(function()
                instance:Destroy()
                destroyed += 1
            end)
        end
    end

    -- Also clear terrain if present.
    pcall(function()
        local terrain = workspace:FindFirstChildOfClass("Terrain")

        if terrain then
            terrain:Clear()
        end
    end)

    print("[RecursiveHop] Destroyed BaseParts:", destroyed)
end

--//==============================================================
--// MAIN
--//==============================================================

task.wait(INITIAL_DELAY)

-- Non-recursive mode:
-- simply move to one different server and stop.
if not recursive_execution then
    local target = chooseServer()

    if not target then
        print("[RecursiveHop] No new server available.")
        destroyEveryPart()
        showDone()
        return
    end

    local targetJobId = tostring(target.id)

    visited[targetJobId] = true
    saveVisited()

    print("[RecursiveHop] Teleporting once to:", targetJobId)

    task.wait(TELEPORT_DELAY)

    local ok, err = pcall(function()
        TeleportService:TeleportToPlaceInstance(
            game.PlaceId,
            targetJobId,
            LocalPlayer
        )
    end)

    if not ok then
        warn("[RecursiveHop] Teleport failed:", err)
    end

    return
end

-- Recursive mode.
while true do
    -- Queue reinjection BEFORE initiating the teleport.
    if not queueSelf() then
        warn("[RecursiveHop] Could not queue reinjection.")
        break
    end

    local target = chooseServer()

    if not target then
        print("[RecursiveHop] No unvisited servers remain.")
        break
    end

    local targetJobId = tostring(target.id)

    -- Mark the target before teleport so it cannot be selected again
    -- if this process gets interrupted and resumed.
    visited[targetJobId] = true
    saveVisited()

    print("[RecursiveHop] Next server:", targetJobId)
    print("[RecursiveHop] Teleporting...")

    task.wait(TELEPORT_DELAY)

    local teleportOk, teleportErr = pcall(function()
        TeleportService:TeleportToPlaceInstance(
            game.PlaceId,
            targetJobId,
            LocalPlayer
        )
    end)

    if not teleportOk then
        warn("[RecursiveHop] Teleport failed:", teleportErr)

        -- Don't loop infinitely on a teleport failure.
        -- The queued script will retry when another teleport happens.
        break
    end

    -- Normally this script terminates here because the client is leaving
    -- the current server. The queued copy starts again after arrival.
    break
end

--//==============================================================
--// EXHAUSTED
--//==============================================================

task.wait(1)

destroyEveryPart()
showDone()

print("[RecursiveHop] done.")
