--!nonstrict
-- Void Linux system update checker service.
-- Checks xbps and flatpak for available updates.

local state = noctalia.state
local settings = noctalia.settings

local auto_check = settings.get("auto_check", true)
local check_interval = settings.get("check_interval", 360)
local flatpak_enabled = settings.get("flatpak_enabled", true)

local xbps_available = false
local flatpak_installed = false

local xbps_updates = {}
local flatpak_updates = {}

local checking = false
local last_check = 0

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
    if findBin("flatpak") then return true end
    if noctalia.fileExists("/usr/bin/flatpak") then return true end
    noctalia.runAsync("flatpak --version", function(result)
        if result.exitCode == 0 then
            flatpak_installed = true
            state.set("flatpak_installed", true)
        end
    end)
    return false
end

local function parseXbpsUpdates(output)
    local updates = {}
    for line in output:gmatch("[^\n]+") do
        local name, version = line:match("^(.+)-(%d[^%s]+)$")
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

local function publishState()
    state.set("checking", checking)
    state.set("last_check", last_check)
    state.set("xbps_updates", xbps_updates)
    state.set("flatpak_updates", flatpak_updates)
end

local function checkUpdates()
    if checking then return end
    checking = true
    publishState()

    xbps_updates = {}
    flatpak_updates = {}

    noctalia.runAsync("xbps-install -Mun 2>/dev/null", function(result)
        if result.exitCode == 0 then
            xbps_updates = parseXbpsUpdates(result.stdout)
        end

        if flatpak_installed then
            noctalia.runAsync("flatpak remote-ls --updates --columns=application,version 2>/dev/null", function(fpResult)
                if fpResult.exitCode == 0 and fpResult.stdout ~= "" then
                    flatpak_updates = parseFlatpakUpdates(fpResult.stdout)
                end
                checking = false
                last_check = os.time()
                publishState()
            end)
        else
            checking = false
            last_check = os.time()
            publishState()
        end
    end)
end

local function updateAll()
    if checking then return end
    if #xbps_updates == 0 and #flatpak_updates == 0 then
        noctalia.notifyError("No Updates", "Nothing to update")
        return
    end

    local commands = {}
    if #xbps_updates > 0 then
        table.insert(commands, "sudo xbps-install -Su -y")
    end
    if #flatpak_updates > 0 then
        table.insert(commands, "flatpak update -y")
    end

    noctalia.runInTerminal(table.concat(commands, " && "))
    checkUpdates()
end

xbps_available = findBin("xbps-install")
flatpak_installed = detectFlatpak()

state.set("xbps_available", xbps_available)
state.set("flatpak_installed", flatpak_installed)

settings.watch("auto_check", function(value)
    auto_check = value
    if auto_check then
        noctalia.setUpdateInterval(check_interval * 60 * 1000)
    end
end)
settings.watch("check_interval", function(value)
    check_interval = value
    if auto_check then
        noctalia.setUpdateInterval(check_interval * 60 * 1000)
    end
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
    noctalia.setUpdateInterval(check_interval * 60 * 1000)
    checkUpdates()
end

function update()
    checkUpdates()
end
