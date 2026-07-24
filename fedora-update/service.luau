--!nonstrict
-- Background service: checks for system updates across dnf and flatpak.
-- Runs all checks in parallel with a safety timeout to prevent
-- the UI from ever getting stuck on "Checking...".
--
-- Safety: all update commands run in a terminal via runInTerminal, giving the
-- user full visibility and control. No commands run silently.

local state = noctalia.state
local checkInterval = (noctalia.getConfig("check_interval") or 360) * 60000
local enableFlatpak = noctalia.getConfig("enable_flatpak")
if enableFlatpak == nil then enableFlatpak = true end
local UPDATE_WAIT = 30

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

state.set("dnf_count", 0)
state.set("flatpak_count", 0)
state.set("total_count", 0)
state.set("dnf_packages", {})
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
    if cmd == "update_dnf" then
        if isUpdating then return end
        isUpdating = true
        updateStartTime = os.time()
        noctalia.runInTerminal("sudo dnf upgrade -y")
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
        local commands = { "sudo dnf upgrade -y" }
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

local function parseDnfPackages(text)
    local packages = {}
    if text == nil or text == "" then
        return packages
    end
    for line in text:gmatch("[^\n]+") do
        line = noctalia.string.trim(line)
        if line ~= "" and not line:match("^Last ") and not line:match("^Obsoleting") and not line:match("^Upgrading") and not line:match("^Dependencies") and not line:match("^Installing") and not line:match("^%-") and not line:match("^Name") then
            local name, version = line:match("^(%S+)%s+(%S+)")
            if name and version then
                table.insert(packages, { name = name, version = version })
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

    local dnfCount = 0
    local flatpakCount = 0
    local dnfPackages = {}
    local flatpakPackages = {}
    local errors = {}

    local expectedCount = 1
    if flatpakInstalled then expectedCount += 1 end

    local completed = 0
    local aggregated = false

    local function aggregateResults()
        if aggregated then return end
        aggregated = true
        state.set("dnf_count", dnfCount)
        state.set("flatpak_count", flatpakCount)
        state.set("total_count", dnfCount + flatpakCount)
        state.set("dnf_packages", dnfPackages)
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
            "Update check: %d dnf, %d flatpak (%d total)",
            dnfCount, flatpakCount,
            dnfCount + flatpakCount
        ))
    end

    local safetyTimer = true
    noctalia.runAsync("sleep 60", function()
        if not safetyTimer then return end
        safetyTimer = false
        if isChecking then
            noctalia.log("Safety timeout: forcing check completion")
            table.insert(errors, "Check timed out")
            aggregateResults()
        end
    end)

    noctalia.runAsync("dnf check-update 2>/dev/null", function(result)
        if result.exitCode == 0 then
            dnfPackages = {}
            dnfCount = 0
        elseif result.exitCode == 100 then
            dnfPackages = parseDnfPackages(result.stdout)
            dnfCount = #dnfPackages
        elseif result.stdout ~= "" then
            table.insert(errors, "dnf: " .. result.stdout:sub(1, 200))
        end
        completed += 1
        if completed == expectedCount then
            safetyTimer = false
            aggregateResults()
        end
    end)

    if flatpakInstalled then
        noctalia.runAsync("flatpak remote-ls --updates --columns=application,version", function(result)
            if result.exitCode == 0 then
                flatpakPackages = parsePackages(result.stdout)
                flatpakCount = #flatpakPackages
            elseif result.exitCode ~= 0 and result.stderr ~= nil and result.stderr ~= "" then
                table.insert(errors, "flatpak: " .. result.stderr)
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
