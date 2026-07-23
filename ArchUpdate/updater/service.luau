--!nonstrict
-- Background service: checks for system updates across pacman, AUR helpers,
-- and flatpak on boot and at configurable intervals. Publishes results to
-- shared state so the bar widget and panel can read them.
--
-- Safety: all update commands run in a terminal via runInTerminal, giving the
-- user full visibility and control. No commands run silently.

local state = noctalia.state
local checkIntervalMinutes = noctalia.getConfig("check_interval_minutes")
if type(checkIntervalMinutes) ~= "number" or checkIntervalMinutes < 5 then
    checkIntervalMinutes = 30
end

local CHECK_INTERVAL_MS = checkIntervalMinutes * 60 * 1000
local FIRST_CHECK_DELAY_MS = 3000

local updating = false
local checking = false

state.set("pacman_count", 0)
state.set("aur_count", 0)
state.set("flatpak_count", 0)
state.set("total_count", 0)
state.set("last_checked", nil)
state.set("checking", false)
state.set("aur_helper", nil)
state.set("flatpak_installed", noctalia.commandExists("flatpak"))

if noctalia.commandExists("paru") then
    state.set("aur_helper", "paru")
elseif noctalia.commandExists("yay") then
    state.set("aur_helper", "yay")
end

local function runSync(cmd)
    local result = nil
    local done = false
    noctalia.runAsync(cmd, function(r)
        result = r
        done = true
    end, 60000)
    local deadline = os.clock() + 65
    while not done and os.clock() < deadline do
        os.execute("sleep 0.1")
    end
    return result
end

local function countLines(text)
    if text == nil or text == "" then
        return 0
    end
    local count = 0
    for _ in text:gmatch("[^\n]+") do
        count += 1
    end
    return count
end

local function checkUpdates()
    if updating or checking then
        return
    end
    checking = true
    state.set("checking", true)

    local pacmanCount = 0
    local aurCount = 0
    local flatpakCount = 0

    local pacmanResult = runSync("pacman -Qu 2>/dev/null")
    if pacmanResult and pacmanResult.exitCode == 0 then
        pacmanCount = countLines(pacmanResult.stdout)
    end

    local aurHelper = state.get("aur_helper")
    if aurHelper then
        local aurResult = runSync(aurHelper .. " -Qua 2>/dev/null")
        if aurResult and aurResult.exitCode == 0 then
            aurCount = countLines(aurResult.stdout)
        end
    end

    if state.get("flatpak_installed") then
        local flatpakResult = runSync("flatpak remote-ls --updates 2>/dev/null | wc -l")
        if flatpakResult and flatpakResult.exitCode == 0 then
            flatpakCount = tonumber(flatpakResult.stdout:match("%d+")) or 0
        end
    end

    local totalCount = pacmanCount + aurCount + flatpakCount

    state.set("pacman_count", pacmanCount)
    state.set("aur_count", aurCount)
    state.set("flatpak_count", flatpakCount)
    state.set("total_count", totalCount)
    state.set("last_checked", os.time())
    state.set("checking", false)
    checking = false

    noctalia.log(string.format(
        "Update check complete: %d pacman, %d aur, %d flatpak (%d total)",
        pacmanCount, aurCount, flatpakCount, totalCount
    ))
end

local function refreshAfterUpdate()
    updating = false
    checkUpdates()
end

function update()
    noctalia.setUpdateInterval(CHECK_INTERVAL_MS)
    if not state.get("initial_check_done") then
        state.set("initial_check_done", true)
        noctalia.runAsync("sleep " .. tostring(FIRST_CHECK_DELAY_MS / 1000), function()
            checkUpdates()
        end)
    end
end

function onIpc(event, payload)
    if event == "check" then
        checkUpdates()
    elseif event == "update_pacman" then
        updating = true
        noctalia.runInTerminal("sudo pacman -Syu --noconfirm")
        noctalia.runAsync("sleep 3", function()
            refreshAfterUpdate()
        end)
    elseif event == "update_aur" then
        local helper = state.get("aur_helper")
        if helper then
            updating = true
            noctalia.runInTerminal(helper .. " -Sua --noconfirm --answerclean None")
            noctalia.runAsync("sleep 3", function()
                refreshAfterUpdate()
            end)
        end
    elseif event == "update_flatpak" then
        if state.get("flatpak_installed") then
            updating = true
            noctalia.runInTerminal("flatpak update -y")
            noctalia.runAsync("sleep 3", function()
                refreshAfterUpdate()
            end)
        end
    elseif event == "update_all" then
        updating = true
        local commands = {}
        table.insert(commands, "sudo pacman -Syu --noconfirm")
        local helper = state.get("aur_helper")
        if helper then
            table.insert(commands, helper .. " -Sua --noconfirm --answerclean None")
        end
        if state.get("flatpak_installed") then
            table.insert(commands, "flatpak update -y")
        end
        local fullCmd = table.concat(commands, " && ")
        noctalia.runInTerminal(fullCmd)
        noctalia.runAsync("sleep 5", function()
            refreshAfterUpdate()
        end)
    end
end

function onExit(_signal)
    noctalia.log("Arch Updater service shutting down")
end
