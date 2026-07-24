local noctalia = noctalia
local state = noctalia.state

local settings = noctalia.settings

-- Settings
local auto_check = settings.get("auto_check", true)
local check_interval = settings.get("check_interval", 3600)
local aur_helper = settings.get("aur_helper", "paru")
local aur_enabled = settings.get("aur_enabled", true)
local flatpak_enabled = settings.get("flatpak_enabled", true)

-- State
local pacman_available = false
local aur_available = false
local flatpak_installed = false

local pacman_updates = {}
local aur_updates = {}
local flatpak_updates = {}

local checking = false
local last_check = 0

local function notify(title, message)
    noctalia.notify(title, message)
end

local function notifyError(message)
    noctalia.notify("Error", message)
end

local function findBin(name)
    if noctalia.commandExists(name) then
        return true
    end
    local dirs = { "/usr/bin", "/usr/local/bin", "/usr/sbin", "/usr/local/sbin", "/usr/lib", "/usr/lib64", "/usr/libexec" }
    for _, dir in ipairs(dirs) do
        if noctalia.fileExists(dir .. "/" .. name) then
            return true
        end
    end
    return false
end

local function detectFlatpak()
    if not flatpak_enabled then return false end
    if findBin("flatpak") then
        return true
    end
    if noctalia.fileExists("/usr/bin/flatpak") then
        return true
    end
    noctalia.runAsync("flatpak --version", function(result)
        if result.exitCode == 0 then
            flatpak_installed = true
            state.set("flatpak_installed", true)
            noctalia.log("Flatpak detected: " .. noctalia.string.trim(result.stdout))
        end
    end)
    return false
end

local function parsePacmanUpdates(output)
    local updates = {}
    for line in output:gmatch("[^\n]+") do
        local name, version = line:match("(.+)/(.+)")
        if name then
            table.insert(updates, { name = name, version = version })
        end
    end
    return updates
end

local function parseAurUpdates(output)
    local updates = {}
    for line in output:gmatch("[^\n]+") do
        local name, version = line:match("(.+)/(.+)")
        if name then
            table.insert(updates, { name = name, version = version })
        end
    end
    return updates
end

local function parseFlatpakUpdates(output)
    local updates = {}
    for line in output:gmatch("[^\n]+") do
        local name, version = line:match("(.+)\t(.+)")
        if name then
            table.insert(updates, { name = name, version = version })
        end
    end
    return updates
end

local function checkUpdates()
    if checking then return end
    checking = true
    state.set("checking", true)

    pacman_updates = {}
    aur_updates = {}
    flatpak_updates = {}

    noctalia.runAsync("pacman -Qu 2>/dev/null", function(result)
        if result.exitCode == 0 then
            pacman_updates = parsePacmanUpdates(result.stdout)
        end

        if aur_enabled then
            noctalia.runAsync(aur_helper .. " -Qua 2>/dev/null", function(aurResult)
                if aurResult.exitCode == 0 then
                    aur_updates = parseAurUpdates(aurResult.stdout)
                end

                if flatpak_installed then
                    noctalia.runAsync("flatpak remote-ls --updates --columns=application,version 2>/dev/null", function(flatpakResult)
                        if flatpakResult.exitCode == 0 and flatpakResult.stdout ~= "" then
                            flatpak_updates = parseFlatpakUpdates(flatpakResult.stdout)
                        end

                        checking = false
                        last_check = os.time()
                        state.set("checking", false)
                        state.set("last_check", last_check)
                        state.set("pacman_updates", pacman_updates)
                        state.set("aur_updates", aur_updates)
                        state.set("flatpak_updates", flatpak_updates)
                    end)
                else
                    checking = false
                    last_check = os.time()
                    state.set("checking", false)
                    state.set("last_check", last_check)
                    state.set("pacman_updates", pacman_updates)
                    state.set("aur_updates", aur_updates)
                end
            end)
        else
            if flatpak_installed then
                noctalia.runAsync("flatpak remote-ls --updates --columns=application,version 2>/dev/null", function(flatpakResult)
                    if flatpakResult.exitCode == 0 and flatpakResult.stdout ~= "" then
                        flatpak_updates = parseFlatpakUpdates(flatpakResult.stdout)
                    end

                    checking = false
                    last_check = os.time()
                    state.set("checking", false)
                    state.set("last_check", last_check)
                    state.set("pacman_updates", pacman_updates)
                    state.set("flatpak_updates", flatpak_updates)
                end)
            else
                checking = false
                last_check = os.time()
                state.set("checking", false)
                state.set("last_check", last_check)
                state.set("pacman_updates", pacman_updates)
            end
        end
    end)
end

local function updateAll()
    if checking then return end
    local has_updates = #pacman_updates > 0 or #aur_updates > 0 or #flatpak_updates > 0
    if not has_updates then
        notifyError("No updates available")
        return
    end

    local commands = {}
    if #pacman_updates > 0 then
        table.insert(commands, "sudo pacman -Syu --noconfirm")
    end
    if #aur_updates > 0 then
        table.insert(commands, aur_helper .. " -Sua --noconfirm")
    end
    if #flatpak_updates > 0 then
        table.insert(commands, "flatpak update -y")
    end

    local cmd = table.concat(commands, " && ")
    noctalia.runAsync(cmd, function(result)
        if result.exitCode == 0 then
            notify("System Updates", "All packages updated successfully")
            checkUpdates()
        else
            notifyError("Failed to update packages")
        end
    end)
end

pacman_available = findBin("pacman")
aur_available = aur_enabled and findBin(aur_helper)
flatpak_installed = detectFlatpak()

state.set("pacman_available", pacman_available)
state.set("aur_available", aur_available)
state.set("flatpak_installed", flatpak_installed)

settings.watch("auto_check", function(value) auto_check = value end)
settings.watch("check_interval", function(value) check_interval = value end)
settings.watch("aur_helper", function(value) aur_helper = value end)
settings.watch("aur_enabled", function(value)
    aur_enabled = value
    aur_available = value and findBin(aur_helper)
    state.set("aur_available", aur_available)
end)
settings.watch("flatpak_enabled", function(value)
    flatpak_enabled = value
    flatpak_installed = detectFlatpak()
    state.set("flatpak_installed", flatpak_installed)
end)

state.watch("command", function(cmd)
    if cmd == "check" then
        checkUpdates()
    elseif cmd == "update_all" then
        updateAll()
    end
end)

if auto_check then
    checkUpdates()
end
