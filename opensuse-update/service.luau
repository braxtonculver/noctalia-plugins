local noctalia = noctalia
local state = noctalia.state

local settings = noctalia.settings

local auto_check = settings.get("auto_check", true)
local check_interval = settings.get("check_interval", 3600)
local flatpak_enabled = settings.get("flatpak_enabled", true)

local zypper_available = false
local flatpak_installed = false

local zypper_updates = {}
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

local function parseZypperUpdates(output)
    local updates = {}
    for line in output:gmatch("[^\n]+") do
        line = noctalia.string.trim(line)
        if line ~= "" and not line:match("^Repository") and not line:match("^%-") and not line:match("^S ") and not line:match("^Status") then
            local fields = {}
            for field in line:gmatch("[^|]+") do
                table.insert(fields, noctalia.string.trim(field))
            end
            if #fields >= 5 then
                table.insert(updates, { name = fields[3], version = fields[5] })
            end
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

    zypper_updates = {}
    flatpak_updates = {}

    noctalia.runAsync("zypper list-updates 2>/dev/null", function(result)
        if result.exitCode == 0 then
            zypper_updates = parseZypperUpdates(result.stdout)
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
                state.set("zypper_updates", zypper_updates)
                state.set("flatpak_updates", flatpak_updates)
            end)
        else
            checking = false
            last_check = os.time()
            state.set("checking", false)
            state.set("last_check", last_check)
            state.set("zypper_updates", zypper_updates)
        end
    end)
end

local function updateAll()
    if checking then return end
    local has_updates = #zypper_updates > 0 or #flatpak_updates > 0
    if not has_updates then
        notifyError("No updates available")
        return
    end

    local commands = {}
    if #zypper_updates > 0 then
        table.insert(commands, "sudo zypper update -y")
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

zypper_available = findBin("zypper")
flatpak_installed = detectFlatpak()

state.set("zypper_available", zypper_available)
state.set("flatpak_installed", flatpak_installed)

settings.watch("auto_check", function(value) auto_check = value end)
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
