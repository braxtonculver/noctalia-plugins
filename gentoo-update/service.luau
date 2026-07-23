--!nonstrict
-- Background service: checks for system updates across portage (emerge) and flatpak.
-- Runs all checks in parallel with a safety timeout to prevent
-- the UI from ever getting stuck on "Checking...".
--
-- Safety: all update commands run in a terminal via runInTerminal, giving the
-- user full visibility and control. No commands run silently.

local state = noctalia.state
local checkInterval = (noctalia.getConfig("check_interval") or 360) * 60000
local enableFlatpak = noctalia.getConfig("enable_flatpak")
if enableFlatpak == nil then enableFlatpak = true end
local UPDATE_WAIT = 60

local isChecking = false
local isUpdating = false
local pendingCheck = false
local updateStartTime = 0

local function findBin(name)
    if noctalia.commandExists(name) then
        return true
    end
    for _, dir in ipairs({ "/usr/bin", "/usr/local/bin", "/usr/sbin", "/usr/local/sbin" }) do
        if noctalia.fileExists(dir .. "/" .. name) then
            return true
        end
    end
    return false
end

local function detectFlatpak()
    if not enableFlatpak then
        return false
    end
    return findBin("flatpak")
end

local flatpakInstalled = detectFlatpak()

state.set("portage_count", 0)
state.set("flatpak_count", 0)
state.set("total_count", 0)
state.set("portage_packages", {})
state.set("flatpak_packages", {})
state.set("last_checked", nil)
state.set("checking", false)
state.set("error", nil)
state.set("flatpak_installed", flatpakInstalled)

local lastRefreshRequest = 0
state.watch("refresh_request", function(timestamp)
    if timestamp ~= nil and timestamp ~= lastRefreshRequest then
        lastRefreshRequest = timestamp
        checkUpdates()
    end
end)

local lastUpdateCmd = ""
local lastUpdateTs = 0
state.watch("update_request", function(value)
    if value == nil then return end
    local cmd = value.command or ""
    local ts = value.ts or 0
    if cmd == lastUpdateCmd and ts == lastUpdateTs then return end
    lastUpdateCmd = cmd
    lastUpdateTs = ts
    if cmd == "update_portage" then
        if isUpdating then return end
        isUpdating = true
        updateStartTime = os.time()
        noctalia.runInTerminal("sudo emerge -uDN @world")
        noctalia.runAsync("sleep " .. UPDATE_WAIT, function()
            isUpdating = false
            checkUpdates()
        end)
    elseif cmd == "update_flatpak" then
        if isUpdating or not flatpakInstalled then return end
        isUpdating = true
        updateStartTime = os.time()
        noctalia.runInTerminal("flatpak update -y")
        noctalia.runAsync("sleep " .. UPDATE_WAIT, function()
            isUpdating = false
            checkUpdates()
        end)
    elseif cmd == "update_all" then
        if isUpdating then return end
        isUpdating = true
        updateStartTime = os.time()
        local commands = { "sudo emerge -uDN @world" }
        if flatpakInstalled then
            table.insert(commands, "flatpak update -y")
        end
        noctalia.runInTerminal(table.concat(commands, " ; "))
        noctalia.runAsync("sleep " .. UPDATE_WAIT, function()
            isUpdating = false
            checkUpdates()
        end)
    end
end)

local function parsePortagePackages(text)
    local packages = {}
    if text == nil or text == "" then
        return packages
    end
    for line in text:gmatch("[^\n]+") do
        if line:match("%[ebuild") then
            local name, newVersion = line:match("%[ebuild[^\"]*%]%s+(%S+)-(%d[^%s]+)")
            if name then
                table.insert(packages, { name = name, version = newVersion })
            end
        end
    end
    return packages
end

local function parsePackages(text)
    local packages = {}
    if text == nil or text == "" then
        return packages
    end
    for line in text:gmatch("[^\n]+") do
        line = noctalia.string.trim(line)
        if line ~= "" then
            local name, version = line:match("^(%S+)%s+(%S+)")
            if name then
                table.insert(packages, { name = name, version = version })
            end
        end
    end
    return packages
end

function checkUpdates()
    if isChecking then
        pendingCheck = true
        return
    end
    isChecking = true
    state.set("checking", true)
    state.set("error", nil)

    local portageCount = 0
    local flatpakCount = 0
    local portagePackages = {}
    local flatpakPackages = {}
    local errors = {}

    local expectedCount = 1
    if flatpakInstalled then expectedCount += 1 end

    local completed = 0
    local aggregated = false

    local function aggregateResults()
        if aggregated then return end
        aggregated = true
        state.set("portage_count", portageCount)
        state.set("flatpak_count", flatpakCount)
        state.set("total_count", portageCount + flatpakCount)
        state.set("portage_packages", portagePackages)
        state.set("flatpak_packages", flatpakPackages)
        state.set("last_checked", os.time())
        state.set("checking", false)
        isChecking = false

        if #errors > 0 then
            state.set("error", table.concat(errors, "; "))
        else
            state.set("error", nil)
        end

        if pendingCheck then
            pendingCheck = false
            checkUpdates()
        end

        noctalia.log(string.format(
            "Update check: %d portage, %d flatpak (%d total)",
            portageCount, flatpakCount,
            portageCount + flatpakCount
        ))
    end

    local safetyTimer = true
    noctalia.runAsync("sleep 90", function()
        if not safetyTimer then return end
        safetyTimer = false
        if isChecking then
            noctalia.log("Safety timeout: forcing check completion")
            table.insert(errors, "Check timed out")
            aggregateResults()
        end
    end)

    noctalia.runAsync("emerge -uDNp @world 2>/dev/null", function(result)
        local output = result.stdout .. "\n" .. (result.stderr or "")
        if result.exitCode == 0 or result.exitCode == 1 then
            portagePackages = parsePortagePackages(output)
            portageCount = #portagePackages
        elseif output ~= "" then
            table.insert(errors, "emerge: " .. output:sub(1, 200))
        end
        completed += 1
        if completed == expectedCount then
            safetyTimer = false
            aggregateResults()
        end
    end)

    if flatpakInstalled then
        noctalia.runAsync("flatpak remote-ls --updates 2>/dev/null", function(result)
            if result.exitCode == 0 then
                flatpakPackages = parsePackages(result.stdout)
                flatpakCount = #flatpakPackages
            end
            completed += 1
            if completed == expectedCount then
                safetyTimer = false
                aggregateResults()
            end
        end)
    end
end

function update()
    noctalia.setUpdateInterval(checkInterval)
    if isUpdating and os.time() - updateStartTime > UPDATE_WAIT * 2 then
        noctalia.log("Safety: resetting stuck update state")
        isUpdating = false
    end
    checkUpdates()
end
