--[[
    Recursive Server Hopper

    CONFIGURATION
]]

local AUTO_REJOIN = true
local REJOIN_SAME_SERVER = false
local recursive_execution = true

-- IMPORTANT:
-- Put the RAW URL of this script here.
local SCRIPT_URL = "https://raw.githubusercontent.com/femce4l20/testies/refs/heads/main/test1.luau"

-- Maximum number of public-server API pages to inspect.
local MAX_SERVER_PAGES = 100

-- Delay before starting.
local INITIAL_DELAY = 1.5

-- Delay immediately before teleporting.
local TELEPORT_DELAY = 0.5

-- Persistent TeleportSetting key.
local VISITED_SETTING = "RecursiveServerHop_Visited_v2"


--==============================================================
-- SERVICES
--==============================================================

local Players = game:GetService("Players")
local TeleportService = game:GetService("TeleportService")
local HttpService = game:GetService("HttpService")

local LocalPlayer = Players.LocalPlayer


--==============================================================
-- EXECUTOR COMPATIBILITY
--==============================================================

local function missing(expectedType, value, fallback)
    if type(value) == expectedType then
        return value
    end

    return fallback
end

local syn = missing("table", syn, nil)
local fluxus = missing("table", fluxus, nil)

local queueteleport = missing(
    "function",
    queue_on_teleport
        or (syn and syn.queue_on_teleport)
        or (fluxus and fluxus.queue_on_teleport)
)


--==============================================================
-- HTTP COMPATIBILITY
--==============================================================

local function getHttp()
    if type(game.HttpGet) == "function" then
        return function(url)
            return game:HttpGet(url)
        end
    end

    local requestFunction =
        request
        or http_request
        or (syn and syn.request)
        or (fluxus and fluxus.request)

    if type(requestFunction) == "function" then
        return function(url)
            local response = requestFunction({
                Url = url,
                Method = "GET"
            })

            if response and response.Body then
                return response.Body
            end

            error("HTTP request returned no body")
        end
    end

    return nil
end

local httpGet = getHttp()


--==============================================================
-- CONFIG VALIDATION
--==============================================================

if not AUTO_REJOIN then
    warn("[RecursiveHop] AUTO_REJOIN = false")
    return
end

if SCRIPT_URL == ""
    or SCRIPT_URL:find("YOUR%-RAW%-SCRIPT%-URL") then

    warn("[RecursiveHop] Set SCRIPT_URL before running.")
    return
end

if recursive_execution and not queueteleport then
    warn("[RecursiveHop] queue_on_teleport is unavailable.")
    warn("[RecursiveHop] Supported forms:")
    warn("  queue_on_teleport")
    warn("  syn.queue_on_teleport")
    warn("  fluxus.queue_on_teleport")

    return
end


--==============================================================
-- PERSISTENT VISITED-SERVER STORAGE
--==============================================================

local visited = {}

local function loadVisited()
    local ok, stored = pcall(function()
        return TeleportService:GetTeleportSetting(VISITED_SETTING)
    end)

    if not ok then
        warn("[RecursiveHop] Could not read teleport settings:", stored)
        return
    end

    if typeof(stored) == "table" then
        for jobId, value in pairs(stored) do
            if value == true then
                visited[tostring(jobId)] = true
            end
        end

        return
    end

    if typeof(stored) == "string" and stored ~= "" then
        local decodeOK, decoded = pcall(function()
            return HttpService:JSONDecode(stored)
        end)

        if decodeOK and typeof(decoded) == "table" then
            for jobId, value in pairs(decoded) do
                if value == true then
                    visited[tostring(jobId)] = true
                end
            end
        end
    end
end

local function saveVisited()
    local copy = {}

    for jobId, value in pairs(visited) do
        if value then
            copy[tostring(jobId)] = true
        end
    end

    local ok, err = pcall(function()
        TeleportService:SetTeleportSetting(
            VISITED_SETTING,
            copy
        )
    end)

    if ok then
        return true
    end

    warn("[RecursiveHop] Table teleport setting failed:", err)

    -- Fallback to a JSON string.
    local encodedOK, encoded = pcall(function()
        return HttpService:JSONEncode(copy)
    end)

    if encodedOK then
        local fallbackOK, fallbackErr = pcall(function()
            TeleportService:SetTeleportSetting(
                VISITED_SETTING,
                encoded
            )
        end)

        if fallbackOK then
            return true
        end

        warn(
            "[RecursiveHop] JSON teleport setting failed:",
            fallbackErr
        )
    end

    return false
end

loadVisited()


--==============================================================
-- CURRENT SERVER
--==============================================================

local currentJobId = tostring(game.JobId)

if currentJobId ~= "" then
    visited[currentJobId] = true
    saveVisited()

    print("[RecursiveHop] Current JobId:", currentJobId)
else
    warn("[RecursiveHop] game.JobId is empty.")
end


--==============================================================
-- AUTO REINJECTION
--
-- This intentionally follows the same structure as the
-- Infinite Yield example:
--
-- local TeleportCheck = false
-- Players.LocalPlayer.OnTeleport:Connect(function(State)
--     if KeepInfYield and (not TeleportCheck) and queueteleport then
--         TeleportCheck = true
--         queueteleport("loadstring(...)()")
--     end
-- end)
--
--==============================================================

local TeleportCheck = false

Players.LocalPlayer.OnTeleport:Connect(function(State)

    if not recursive_execution then
        return
    end

    if TeleportCheck then
        return
    end

    if not queueteleport then
        warn("[RecursiveHop] Missing queue_on_teleport.")
        return
    end

    TeleportCheck = true

    local queuedLoader = string.format(
        "loadstring(game:HttpGet(%q))()",
        SCRIPT_URL
    )

    local ok, err = pcall(function()
        queueteleport(queuedLoader)
    end)

    if ok then
        print("[RecursiveHop] Script queued for next server.")
    else
        warn(
            "[RecursiveHop] queue_on_teleport failed:",
            err
        )
    end
end)


--==============================================================
-- SERVER API
--==============================================================

local function fetchServers()
    local servers = {}
    local cursor = nil

    if not httpGet then
        warn("[RecursiveHop] No compatible HTTP function.")
        return servers
    end

    for page = 1, MAX_SERVER_PAGES do

        local url =
            ("https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=Asc&limit=100")
            :format(game.PlaceId)

        if cursor and cursor ~= "" then
            url = url
                .. "&cursor="
                .. HttpService:UrlEncode(cursor)
        end

        local body

        local requestOK, requestErr = pcall(function()
            body = httpGet(url)
        end)

        if not requestOK then
            warn(
                "[RecursiveHop] Server request failed:",
                requestErr
            )

            break
        end

        local data

        local decodeOK, decodeErr = pcall(function()
            data = HttpService:JSONDecode(body)
        end)

        if not decodeOK then
            warn(
                "[RecursiveHop] Failed to decode server response:",
                decodeErr
            )

            break
        end

        if typeof(data) ~= "table" then
            warn("[RecursiveHop] Server response was not a table.")
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


--==============================================================
-- FIND AN UNVISITED SERVER
--==============================================================

local function chooseServer()
    local servers = fetchServers()

    print(
        "[RecursiveHop] Server entries found:",
        #servers
    )

    local candidates = {}
    local fallbackCandidates = {}

    for _, server in ipairs(servers) do

        local jobId = tostring(server.id)

        local isCurrentServer =
            jobId == currentJobId

        local wasVisited =
            visited[jobId] == true

        if not wasVisited
            and (
                REJOIN_SAME_SERVER
                or not isCurrentServer
            ) then

            table.insert(
                fallbackCandidates,
                server
            )

            local playing =
                tonumber(server.playing) or 0

            local maxPlayers =
                tonumber(server.maxPlayers) or 0

            if maxPlayers <= 0
                or playing < maxPlayers then

                table.insert(
                    candidates,
                    server
                )
            end
        end
    end

    -- Prefer non-full servers.
    if #candidates > 0 then
        return candidates[
            math.random(1, #candidates)
        ]
    end

    -- If all available servers looked full,
    -- still try any unvisited server.
    if #fallbackCandidates > 0 then
        return fallbackCandidates[
            math.random(
                1,
                #fallbackCandidates
            )
        ]
    end

    return nil
end


--==============================================================
-- DONE UI
--==============================================================

local function showDone()
    local PlayerGui =
        LocalPlayer:FindFirstChildOfClass(
            "PlayerGui"
        )

    if not PlayerGui then
        warn("[RecursiveHop] PlayerGui unavailable.")
        return
    end

    local old =
        PlayerGui:FindFirstChild(
            "RecursiveHopDone"
        )

    if old then
        old:Destroy()
    end

    local ScreenGui =
        Instance.new("ScreenGui")

    ScreenGui.Name =
        "RecursiveHopDone"

    ScreenGui.ResetOnSpawn =
        false

    ScreenGui.IgnoreGuiInset =
        true

    ScreenGui.DisplayOrder =
        2147483647

    local Background =
        Instance.new("Frame")

    Background.Name =
        "Background"

    Background.Size =
        UDim2.fromScale(1, 1)

    Background.Position =
        UDim2.fromScale(0, 0)

    Background.BorderSizePixel =
        0

    Background.BackgroundColor3 =
        Color3.fromRGB(0, 0, 0)

    Background.BackgroundTransparency =
        0.15

    Background.Parent =
        ScreenGui

    local Label =
        Instance.new("TextLabel")

    Label.Name =
        "Done"

    Label.AnchorPoint =
        Vector2.new(0.5, 0.5)

    Label.Position =
        UDim2.fromScale(0.5, 0.5)

    Label.Size =
        UDim2.fromScale(0.8, 0.2)

    Label.BackgroundTransparency =
        1

    Label.Text =
        "done."

    Label.TextColor3 =
        Color3.fromRGB(255, 255, 255)

    Label.TextScaled =
        true

    Label.Font =
        Enum.Font.GothamBold

    Label.Parent =
        Background

    ScreenGui.Parent =
        PlayerGui
end


--==============================================================
-- DELETE EVERY PART
--==============================================================

local function destroyEveryPart()
    local descendants =
        game:GetDescendants()

    local destroyed = 0

    for _, instance in ipairs(descendants) do

        if instance:IsA("BasePart") then

            pcall(function()
                instance:Destroy()
                destroyed += 1
            end)

        end
    end

    -- Clear Terrain separately.
    pcall(function()
        local terrain =
            workspace:FindFirstChildOfClass(
                "Terrain"
            )

        if terrain then
            terrain:Clear()
        end
    end)

    print(
        "[RecursiveHop] Destroyed parts:",
        destroyed
    )
end


--==============================================================
-- TELEPORT TO NEXT SERVER
--==============================================================

local function teleportToServer(server)
    if not server or not server.id then
        return false
    end

    local targetJobId =
        tostring(server.id)

    -- Prevent this target from being chosen again.
    visited[targetJobId] = true
    saveVisited()

    print(
        "[RecursiveHop] Target server:",
        targetJobId
    )

    task.wait(TELEPORT_DELAY)

    local ok, err = pcall(function()
        TeleportService:TeleportToPlaceInstance(
            game.PlaceId,
            targetJobId,
            LocalPlayer
        )
    end)

    if not ok then
        warn(
            "[RecursiveHop] Teleport failed:",
            err
        )

        return false
    end

    return true
end


--==============================================================
-- MAIN
--==============================================================

task.wait(INITIAL_DELAY)


--==============================================================
-- NON-RECURSIVE MODE
--==============================================================

if not recursive_execution then

    local target =
        chooseServer()

    if not target then
        print(
            "[RecursiveHop] No unvisited servers remain."
        )

        destroyEveryPart()
        showDone()

        return
    end

    teleportToServer(target)

    return
end


--==============================================================
-- RECURSIVE MODE
--
-- Important:
-- The script DOES NOT manually call the queue function here.
--
-- queue_on_teleport is triggered from OnTeleport above.
--
-- That means:
--
--     TeleportToPlaceInstance()
--             ↓
--     OnTeleport fires
--             ↓
--     queue_on_teleport(loader)
--             ↓
--     teleport completes
--             ↓
--     loader executes
--             ↓
--     script starts again
--
--==============================================================

local target =
    chooseServer()

if not target then

    print(
        "[RecursiveHop] No unvisited servers remain."
    )

    destroyEveryPart()
    showDone()

    return
end

local success =
    teleportToServer(target)

if not success then
    warn(
        "[RecursiveHop] Unable to teleport to selected server."
    )
end
