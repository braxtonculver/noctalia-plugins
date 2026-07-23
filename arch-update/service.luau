--!nonstrict
-- Background service: checks for system updates across pacman, AUR helpers,
-- and flatpak on boot and at configurable intervals. Publishes results to
-- shared state so the bar widget and panel can read them.
--
-- Safety: all update commands run in a terminal via runInTerminal, giving the
-- user full visibility and control. No commands run silently.

local state = noctalia.state
local interval = (noctalia.getConfig("check_interval") or 300) * 1000

local updating = false
local isChecking = false

state.set("pacman_count", 0)
state.set("aur_count", 0)
state.set("flatpak_count", 0)
state.set("total_count", 0)
state.set("last_checked", nil)
state.set("checking", false)
state.set("error", nil)

local aurHelper = nil
if noctalia.commandExists("paru") then
    aurHelper = "paru"
elseif noctalia.commandExists("yay") then
    aurHelper = "yay"
end
state.set("aur_helper", aurHelper)
state.set("flatpak_installed", noctalia.commandExists("flatpak"))

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
    if updating or isChecking then
        return
    end
    isChecking = true
    state.set("checking", true)
    state.set("error", nil)

    local pacmanCount = 0
    local aurCount = 0
    local flatpakCount = 0
    local errors = {}

    noctalia.runAsync("pacman -Qu 2>/dev/null", function(result)
        if result.exitCode == 0 then
            pacmanCount = countLines(result.stdout)
        elseif result.stdout ~= "" then
            table.insert(errors, "pacman: " .. result.stdout)
        end

        local function nextStep()
            local totalCount = pacmanCount + aurCount + flatpakCount
            state.set("pacman_count", pacmanCount)
            state.set("aur_count", aurCount)
            state.set("flatpak_count", flatpakCount)
            state.set("total_count", totalCount)
            state.set("last_checked", os.time())
            state.set("checking", false)
            isChecking = false

            if #errors > 0 then
                state.set("error", table.concat(errors, "; "))
            else
                state.set("error", nil)
            end

            noctalia.log(string.format(
                "Update check: %d pacman, %d aur, %d flatpak (%d total)",
                pacmanCount, aurCount, flatpakCount, totalCount
            ))
        end

        if aurHelper then
            noctalia.runAsync(aurHelper .. " -Qua 2>/dev/null", function(aurResult)
                if aurResult.exitCode == 0 then
                    aurCount = countLines(aurResult.stdout)
                elseif aurResult.stdout ~= "" then
                    table.insert(errors, "aur: " .. aurResult.stdout)
                end

                if state.get("flatpak_installed") then
                    noctalia.runAsync("flatpak remote-ls --updates 2>/dev/null", function(fpResult)
                        if fpResult.exitCode == 0 then
                            flatpakCount = countLines(fpResult.stdout)
                        end
                        nextStep()
                    end)
                else
                    nextStep()
                end
            end)
        elseif state.get("flatpak_installed") then
            noctalia.runAsync("flatpak remote-ls --updates 2>/dev/null", function(fpResult)
                if fpResult.exitCode == 0 then
                    flatpakCount = countLines(fpResult.stdout)
                end
                nextStep()
            end)
        else
            nextStep()
        end
    end)
end

function update()
    noctalia.setUpdateInterval(interval)
    if not state.get("initial_check_done") then
        state.set("initial_check_done", true)
        noctalia.runAsync("sleep 3", function()
            checkUpdates()
        end)
    end
end

function onIpc(event, _payload)
    if event == "check" then
        checkUpdates()
    elseif event == "update_pacman" then
        updating = true
        noctalia.runInTerminal("sudo pacman -Syu --noconfirm")
        noctalia.runAsync("sleep 3", function()
            updating = false
            checkUpdates()
        end)
    elseif event == "update_aur" then
        if aurHelper then
            updating = true
            noctalia.runInTerminal(aurHelper .. " -Sua --noconfirm --answerclean None")
            noctalia.runAsync("sleep 3", function()
                updating = false
                checkUpdates()
            end)
        end
    elseif event == "update_flatpak" then
        if state.get("flatpak_installed") then
            updating = true
            noctalia.runInTerminal("flatpak update -y")
            noctalia.runAsync("sleep 3", function()
                updating = false
                checkUpdates()
            end)
        end
    elseif event == "update_all" then
        updating = true
        local commands = { "sudo pacman -Syu --noconfirm" }
        if aurHelper then
            table.insert(commands, aurHelper .. " -Sua --noconfirm --answerclean None")
        end
        if state.get("flatpak_installed") then
            table.insert(commands, "flatpak update -y")
        end
        noctalia.runInTerminal(table.concat(commands, " && "))
        noctalia.runAsync("sleep 5", function()
            updating = false
            checkUpdates()
        end)
    end
end
