--!nonstrict
-- Arch Linux updater panel.
-- Shows update status, package lists per manager, and update actions.

local state = noctalia.state
local panel = noctalia.panel

local pacman_updates = {}
local aur_updates = {}
local flatpak_updates = {}
local pacman_available = false
local aur_available = false
local flatpak_installed = false
local checking = false
local last_check = 0
local search_query = ""
local show_all_pacman = false
local show_all_aur = false
local show_all_flatpak = false

local render

local function formatTimestamp(ts)
    if ts == 0 then return "Never" end
    return noctalia.formatTime(ts, "%H:%M")
end

local function getTotalCount()
    return #pacman_updates + #aur_updates + #flatpak_updates
end

local function managerSection(name, glyph_name, accent, updates, show_all, toggleFn, search)
    local count = #updates
    local has_updates = count > 0

    local filtered = updates
    if search ~= "" and search ~= nil then
        filtered = {}
        local q = search:lower()
        for _, pkg in ipairs(updates) do
            if pkg.name:lower():find(q, 1, true) then
                table.insert(filtered, pkg)
            end
        end
    end

    local rows = {}
    if has_updates then
        local display = filtered
        if not show_all and #display > 10 then
            display = {}
            for i = 1, 10 do
                table.insert(display, filtered[i])
            end
        end
        for _, pkg in ipairs(display) do
            table.insert(rows, ui.row({ gap = 8, align = "center", paddingH = 4, paddingV = 2 }, {
                ui.label({ text = pkg.name, flexGrow = 1, fontSize = 12 }),
                ui.label({ text = pkg.version, color = "on_surface_variant", fontSize = 11 }),
            }))
        end
        if #filtered > 10 and not show_all then
            table.insert(rows, ui.button({
                text = "Show all " .. #filtered,
                onClick = toggleFn,
                variant = "ghost",
            }))
        end
    else
        table.insert(rows, ui.label({ text = "All packages up to date", color = "success", fontSize = 12 }))
    end

    table.insert(rows, 1, ui.row({ gap = 8, align = "center" }, {
        ui.glyph({ name = glyph_name, size = 16, color = accent }),
        ui.label({ text = name, fontWeight = "bold", flexGrow = 1, fontSize = 13 }),
        ui.label({
            text = tostring(count) .. " update" .. (count ~= 1 and "s" or ""),
            color = has_updates and accent or "success",
            fontSize = 12,
            fontWeight = "medium",
        }),
    }))

    return ui.column({ gap = 6, paddingH = 12, paddingV = 10, radius = 10 }, rows)
end

render = function()
    local total = getTotalCount()
    local has_updates = total > 0

    local status_hero
    if checking then
        status_hero = ui.column({ gap = 10, paddingH = 24, paddingV = 20, radius = 16, align = "center" }, {
            ui.glyph({ name = "loader", size = 28, color = "primary" }),
            ui.label({ text = "Checking for updates...", color = "primary", fontWeight = "medium" }),
        })
    elseif has_updates then
        status_hero = ui.column({ gap = 6, paddingH = 24, paddingV = 20, radius = 16, align = "center" }, {
            ui.label({ text = tostring(total), fontSize = 42, fontWeight = "bold", color = "error" }),
            ui.label({ text = "update" .. (total ~= 1 and "s" or "") .. " available", color = "on_surface_variant", fontSize = 13 }),
        })
    else
        status_hero = ui.column({ gap = 8, paddingH = 24, paddingV = 20, radius = 16, align = "center" }, {
            ui.glyph({ name = "circle-check", size = 32, color = "success" }),
            ui.label({ text = "System is up to date", color = "success", fontWeight = "medium", fontSize = 13 }),
        })
    end

    local sections = {
        managerSection("Pacman", "package", "primary", pacman_updates, show_all_pacman, "onToggleShowAllPacman", search_query),
    }
    if aur_available then
        table.insert(sections, managerSection("AUR", "building", "tertiary", aur_updates, show_all_aur, "onToggleShowAllAur", search_query))
    end
    if flatpak_installed then
        table.insert(sections, managerSection("Flatpak", "box", "info", flatpak_updates, show_all_flatpak, "onToggleShowAllFlatpak", search_query))
    end

    local body = { status_hero }
    if has_updates then
        table.insert(body, ui.input({ key = "search", placeholder = "Search packages...", value = search_query, onChange = "onSearchChanged" }))
    end
    for _, s in ipairs(sections) do
        table.insert(body, s)
    end

    panel.render(ui.column({ flexGrow = 1, gap = 16 }, {
        ui.row({ align = "center", gap = 8 }, {
            ui.label({ text = "System Updates", fontSize = 16, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
            ui.button({ glyph = "close", onClick = "onClosePanel" }),
        }),
        ui.scroll({ flexGrow = 1, gap = 12 }, body),
        ui.row({ gap = 8, align = "center" }, {
            ui.label({ text = "Last checked: " .. formatTimestamp(last_check), fontSize = 11, color = "on_surface_variant", flexGrow = 1 }),
            ui.button({ text = "Check", onClick = "onCheckClicked", variant = "secondary" }),
            ui.button({ text = "Update All", onClick = "onUpdateAllClicked", variant = "primary" }),
        }),
    }))
end

function onOpen(_context)
    pacman_updates = state.get("pacman_updates") or {}
    aur_updates = state.get("aur_updates") or {}
    flatpak_updates = state.get("flatpak_updates") or {}
    pacman_available = state.get("pacman_available") or false
    aur_available = state.get("aur_available") or false
    flatpak_installed = state.get("flatpak_installed") or false
    checking = state.get("checking") or false
    last_check = state.get("last_check") or 0
    render()
end

function onClosePanel()
    panel.close()
end

function onCheckClicked()
    state.set("command", "check")
end

function onUpdateAllClicked()
    state.set("command", "update_all")
end

function onSearchChanged(value)
    search_query = value or ""
    render()
end

function onToggleShowAllPacman()
    show_all_pacman = not show_all_pacman
    render()
end

function onToggleShowAllAur()
    show_all_aur = not show_all_aur
    render()
end

function onToggleShowAllFlatpak()
    show_all_flatpak = not show_all_flatpak
    render()
end

noctalia.state.watch("checking", function(v) checking = v or false; render() end)
noctalia.state.watch("last_check", function(v) last_check = v or 0; render() end)
noctalia.state.watch("pacman_updates", function(v) pacman_updates = v or {}; render() end)
noctalia.state.watch("aur_updates", function(v) aur_updates = v or {}; render() end)
noctalia.state.watch("flatpak_updates", function(v) flatpak_updates = v or {}; render() end)
noctalia.state.watch("pacman_available", function(v) pacman_available = v or false; render() end)
noctalia.state.watch("aur_available", function(v) aur_available = v or false; render() end)
noctalia.state.watch("flatpak_installed", function(v) flatpak_installed = v or false; render() end)
