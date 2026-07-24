local noctalia = noctalia
local state = noctalia.state
local settings = noctalia.settings

local auto_check = settings.get("auto_check", true)
local check_interval = settings.get("check_interval", 3600)
local flatpak_enabled = settings.get("flatpak_enabled", true)

local flatpak_installed = false
local dnf_updates = {}
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

local function parseDnfUpdates(output)
    local updates = {}
    for line in output:gmatch("[^\n]+") do
        local name, old_ver, new_ver, repo = line:match("^(%S+)%s+(%S+)%s+(%S+)%s+(%S+)")
        if name then
            table.insert(updates, { name = name, version = new_ver })
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
    last_check = os.time()
    state.set("checking", false)
    state.set("last_check", last_check)
    state.set("dnf_updates", dnf_updates)
    state.set("flatpak_updates", flatpak_updates)
    checking = false
end

local function checkUpdates()
    if checking then return end
    checking = true
    state.set("checking", true)

    dnf_updates = {}
    flatpak_updates = {}

    noctalia.runAsync("dnf check-update 2>/dev/null", function(result)
        if result.exitCode == 100 and result.stdout ~= "" then
            dnf_updates = parseDnfUpdates(result.stdout)
        end

        if flatpak_installed then
            noctalia.runAsync("flatpak remote-ls --updates --columns=application,version 2>/dev/null", function(flatpakResult)
                if flatpakResult.exitCode == 0 and flatpakResult.stdout ~= "" then
                    flatpak_updates = parseFlatpakUpdates(flatpakResult.stdout)
                end
                publishState()
            end)
        else
            publishState()
        end
    end)
end

local function updateAll()
    if checking then return end
    local has_dnf = #dnf_updates > 0
    local has_flatpak = #flatpak_updates > 0
    if not has_dnf and not has_flatpak then return end

    local commands = {}
    if has_dnf then
        table.insert(commands, "sudo dnf upgrade -y")
    end
    if has_flatpak then
        table.insert(commands, "flatpak update -y")
    end

    local cmd = table.concat(commands, " && ")
    noctalia.runAsync(cmd, function(result)
        checkUpdates()
    end)
end

flatpak_installed = detectFlatpak()
state.set("flatpak_installed", flatpak_installed)

settings.watch("check_interval", function(value) check_interval = value end)
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
