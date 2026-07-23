--!nonstrict
-- Background service: checks for system updates across pacman, AUR helpers,
-- and flatpak. Runs all checks in parallel with a safety timeout to prevent
-- the UI from ever getting stuck on "Checking...".
--
-- Safety: all update commands run in a terminal via runInTerminal, giving the
-- user full visibility and control. No commands run silently.

local state = noctalia.state
local checkInterval = (noctalia.getConfig("check_interval") or 360) * 60000
local enableAur = noctalia.getConfig("enable_aur")
if enableAur == nil then enableAur = true end
local enableFlatpak = noctalia.getConfig("enable_flatpak")
if enableFlatpak == nil then enableFlatpak = true end
local aurHelperChoice = noctalia.getConfig("aur_helper") or "auto"
local SAFETY_TIMEOUT = 45000
local UPDATE_WAIT = 30

local isChecking = false
local isUpdating = false
local pendingCheck = false

-- Detect package managers
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

local function detectAurHelper()
    if not enableAur then
        return nil
    end
    if aurHelperChoice == "yay" then
        return findBin("yay") and "yay" or nil
    elseif aurHelperChoice == "paru" then
        return findBin("paru") and "paru" or nil
    else
        -- auto: prefer paru, then yay
        if findBin("paru") then return "paru" end
        if findBin("yay") then return "yay" end
        return nil
    end
end

local function detectFlatpak()
    if not enableFlatpak then
        return false
    end
    return findBin("flatpak")
end

local aurHelper = detectAurHelper()
local flatpakInstalled = detectFlatpak()

state.set("pacman_count", 0)
state.set("aur_count", 0)
state.set("flatpak_count", 0)
state.set("total_count", 0)
state.set("pacman_packages", {})
state.set("aur_packages", {})
state.set("flatpak_packages", {})
state.set("last_checked", nil)
state.set("checking", false)
state.set("error", nil)
state.set("aur_helper", aurHelper)
state.set("flatpak_installed", flatpakInstalled)

-- Watch for refresh requests from the panel (more reliable than IPC).
-- The panel sets this timestamp when the user clicks Refresh.
local lastRefreshRequest = 0
state.watch("refresh_request", function(timestamp)
    if timestamp ~= nil and timestamp ~= lastRefreshRequest then
        lastRefreshRequest = timestamp
        checkUpdates()
    end
end)

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

    local pacmanCount = 0
    local aurCount = 0
    local flatpakCount = 0
    local pacmanPackages = {}
    local aurPackages = {}
    local flatpakPackages = {}
    local errors = {}

    -- Determine how many checks we need
    local expectedCount = 1 -- pacman is always checked
    if aurHelper then expectedCount += 1 end
    if flatpakInstalled then expectedCount += 1 end

    local completed = 0

    local function aggregateResults()
        state.set("pacman_count", pacmanCount)
        state.set("aur_count", aurCount)
        state.set("flatpak_count", flatpakCount)
        state.set("total_count", pacmanCount + aurCount + flatpakCount)
        state.set("pacman_packages", pacmanPackages)
        state.set("aur_packages", aurPackages)
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
            "Update check: %d pacman, %d aur, %d flatpak (%d total)",
            pacmanCount, aurCount, flatpakCount,
            pacmanCount + aurCount + flatpakCount
        ))
    end

    -- Safety timeout: if any check hangs, force completion
    local safetyTimer = false
    noctalia.runAsync("sleep 45", function()
        if not safetyTimer then return end
        safetyTimer = false
        if isChecking then
            noctalia.log("Safety timeout: forcing check completion")
            table.insert(errors, "Check timed out")
            aggregateResults()
        end
    end)

    -- Pacman check (always runs)
    noctalia.runAsync("pacman -Qu 2>/dev/null", function(result)
        if result.exitCode == 0 then
            pacmanPackages = parsePackages(result.stdout)
            pacmanCount = #pacmanPackages
        elseif result.stdout ~= "" then
            table.insert(errors, "pacman: " .. result.stdout)
        end
        completed += 1
        if completed == expectedCount then
            safetyTimer = false
            aggregateResults()
        end
    end)

    -- AUR check (parallel, if helper detected)
    if aurHelper then
        noctalia.runAsync(aurHelper .. " -Qua 2>/dev/null", function(result)
            if result.exitCode == 0 then
                aurPackages = parsePackages(result.stdout)
                aurCount = #aurPackages
            elseif result.stdout ~= "" then
                table.insert(errors, "aur: " .. result.stdout)
            end
            completed += 1
            if completed == expectedCount then
                safetyTimer = false
                aggregateResults()
            end
        end)
    end

    -- Flatpak check (parallel, if installed)
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
    checkUpdates()
end

function onIpc(event, _payload)
    if event == "check" then
        checkUpdates()
    elseif event == "update_pacman" then
        if isUpdating then return end
        isUpdating = true
        noctalia.runInTerminal("sudo pacman -Syu --noconfirm")
        noctalia.runAsync("sleep " .. UPDATE_WAIT, function()
            isUpdating = false
            checkUpdates()
        end)
    elseif event == "update_aur" then
        if isUpdating or not aurHelper then return end
        isUpdating = true
        noctalia.runInTerminal(aurHelper .. " -Sua --noconfirm")
        noctalia.runAsync("sleep " .. UPDATE_WAIT, function()
            isUpdating = false
            checkUpdates()
        end)
    elseif event == "update_flatpak" then
        if isUpdating or not flatpakInstalled then return end
        isUpdating = true
        noctalia.runInTerminal("flatpak update -y")
        noctalia.runAsync("sleep " .. UPDATE_WAIT, function()
            isUpdating = false
            checkUpdates()
        end)
    elseif event == "update_all" then
        if isUpdating then return end
        isUpdating = true
        local commands = { "sudo pacman -Syu --noconfirm" }
        if aurHelper then
            table.insert(commands, aurHelper .. " -Sua --noconfirm")
        end
        if flatpakInstalled then
            table.insert(commands, "flatpak update -y")
        end
        noctalia.runInTerminal(table.concat(commands, " ; "))
        noctalia.runAsync("sleep " .. UPDATE_WAIT, function()
            isUpdating = false
            checkUpdates()
        end)
    end
end
