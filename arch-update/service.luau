--!nonstrict
-- Background service: checks for system updates across pacman, AUR helpers,
-- and flatpak on boot and at configurable intervals. Publishes results to
-- shared state so the bar widget and panel can read them.
--
-- Safety: all update commands run in a terminal via runInTerminal, giving the
-- user full visibility and control. No commands run silently.

local state = noctalia.state
local checkInterval = (noctalia.getConfig("check_interval") or 300) * 1000

local isChecking = false
local isUpdating = false
local pendingCheck = false

local aurHelper = nil
if noctalia.commandExists("paru") then
    aurHelper = "paru"
elseif noctalia.commandExists("yay") then
    aurHelper = "yay"
end
local flatpakInstalled = noctalia.commandExists("flatpak")

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

local function checkComplete(errors)
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

    noctalia.runAsync("pacman -Qu 2>/dev/null", function(result)
        if result.exitCode == 0 then
            pacmanPackages = parsePackages(result.stdout)
            pacmanCount = #pacmanPackages
        elseif result.stdout ~= "" then
            table.insert(errors, "pacman: " .. result.stdout)
        end

        local function afterAur()
            local function afterFlatpak()
                state.set("pacman_count", pacmanCount)
                state.set("aur_count", aurCount)
                state.set("flatpak_count", flatpakCount)
                state.set("total_count", pacmanCount + aurCount + flatpakCount)
                state.set("pacman_packages", pacmanPackages)
                state.set("aur_packages", aurPackages)
                state.set("flatpak_packages", flatpakPackages)
                state.set("last_checked", os.time())
                checkComplete(errors)

                noctalia.log(string.format(
                    "Update check: %d pacman, %d aur, %d flatpak (%d total)",
                    pacmanCount, aurCount, flatpakCount,
                    pacmanCount + aurCount + flatpakCount
                ))
            end

            if flatpakInstalled then
                noctalia.runAsync("flatpak remote-ls --updates 2>/dev/null", function(fpResult)
                    if fpResult.exitCode == 0 then
                        local packages = parsePackages(fpResult.stdout)
                        flatpakCount = #packages
                        flatpakPackages = packages
                    end
                    afterFlatpak()
                end)
            else
                afterFlatpak()
            end
        end

        if aurHelper then
            noctalia.runAsync(aurHelper .. " -Qua 2>/dev/null", function(aurResult)
                if aurResult.exitCode == 0 then
                    aurPackages = parsePackages(aurResult.stdout)
                    aurCount = #aurPackages
                elseif aurResult.stdout ~= "" then
                    table.insert(errors, "aur: " .. aurResult.stdout)
                end
                afterAur()
            end)
        else
            afterAur()
        end
    end)
end

function update()
    noctalia.setUpdateInterval(checkInterval)
    checkUpdates()
end

function onIpc(event, _payload)
    if event == "check" then
        checkUpdates()
    elseif event == "update_pacman" then
        if isUpdating then
            return
        end
        isUpdating = true
        noctalia.runInTerminal("sudo pacman -Syu --noconfirm")
        noctalia.runAsync("sleep 3", function()
            isUpdating = false
            checkUpdates()
        end)
    elseif event == "update_aur" then
        if isUpdating or not aurHelper then
            return
        end
        isUpdating = true
        noctalia.runInTerminal(aurHelper .. " -Sua --noconfirm --answerclean None")
        noctalia.runAsync("sleep 3", function()
            isUpdating = false
            checkUpdates()
        end)
    elseif event == "update_flatpak" then
        if isUpdating or not flatpakInstalled then
            return
        end
        isUpdating = true
        noctalia.runInTerminal("flatpak update -y")
        noctalia.runAsync("sleep 3", function()
            isUpdating = false
            checkUpdates()
        end)
    elseif event == "update_all" then
        if isUpdating then
            return
        end
        isUpdating = true
        local commands = { "sudo pacman -Syu --noconfirm" }
        if aurHelper then
            table.insert(commands, aurHelper .. " -Sua --noconfirm --answerclean None")
        end
        if flatpakInstalled then
            table.insert(commands, "flatpak update -y")
        end
        noctalia.runInTerminal(table.concat(commands, " && "))
        noctalia.runAsync("sleep 5", function()
            isUpdating = false
            checkUpdates()
        end)
    end
end
