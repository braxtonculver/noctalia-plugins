local noctalia = noctalia
local state = noctalia.state
local panel = noctalia.panel

local portage_updates = {}
local flatpak_updates = {}
local portage_available = state.get("portage_available") or false
local flatpak_installed = state.get("flatpak_installed") or false
local checking = state.get("checking") or false
local last_check = state.get("last_check") or 0
local search_query = ""
local show_all_portage = false
local show_all_flatpak = false

local function onCloseClicked()
    panel.close()
end

local function onCheckClicked()
    state.set("command", "check")
end

local function onUpdateAllClicked()
    state.set("command", "update_all")
end

local function onSearchChanged(value)
    search_query = value
    render()
end

local function onToggleShowAllPortage()
    show_all_portage = not show_all_portage
    render()
end

local function onToggleShowAllFlatpak()
    show_all_flatpak = not show_all_flatpak
    render()
end

local function formatTimestamp(ts)
    if ts == 0 then return "Never" end
    return noctalia.formatTime(ts, "%H:%M")
end

local function filterPackages(packages, query)
    if query == "" then return packages end
    local filtered = {}
    local q = query:lower()
    for _, pkg in ipairs(packages) do
        if pkg.name:lower():find(q, 1, true) then
            table.insert(filtered, pkg)
        end
    end
    return filtered
end

local function getPortageCount()
    return #portage_updates
end

local function getFlatpakCount()
    return #flatpak_updates
end

local function getTotalCount()
    return getPortageCount() + getFlatpakCount()
end

local function renderPortageSection()
    local count = getPortageCount()
    local has_updates = count > 0

    local header = ui.row({
        align = "center",
        gap = 8,
        fill = "horizontal",
    }, {
        ui.glyph({ name = "package", size = 16, color = "tertiary" }),
        ui.label({
            text = "Portage",
            fontSize = 13,
            fontWeight = "bold",
            color = "on_surface",
            flexGrow = 1,
        }),
        ui.label({
            text = tostring(count) .. " update" .. (count ~= 1 and "s" or ""),
            fontSize = 12,
            color = has_updates and "tertiary" or "success",
            fontWeight = "medium",
        }),
    })

    local items = {}
    if has_updates then
        local display_updates = portage_updates
        if not show_all_portage and #display_updates > 10 then
            local sliced = {}
            for i = 1, 10 do
                table.insert(sliced, display_updates[i])
            end
            display_updates = sliced
        end

        for _, pkg in ipairs(display_updates) do
            table.insert(items, ui.row({
                fill = "horizontal",
                paddingH = 8,
                paddingV = 4,
                radius = 6,
                align = "center",
                gap = 8,
            }, {
                ui.label({
                    text = pkg.name,
                    fontSize = 12,
                    color = "on_surface",
                    flexGrow = 1,
                    ellipsize = "end",
                }),
                ui.label({
                    text = pkg.version,
                    fontSize = 11,
                    color = "on_surface_variant",
                }),
            }))
        end

        if #portage_updates > 10 and not show_all_portage then
            table.insert(items, ui.button({
                label = "Show all " .. #portage_updates .. " packages",
                onClick = "onToggleShowAllPortage",
                size = "sm",
                fill = "horizontal",
            }))
        end
    else
        table.insert(items, ui.label({
            text = "All packages up to date",
            fontSize = 12,
            color = "success",
            alignment = "center",
            paddingH = 8,
            paddingV = 8,
        }))
    end

    local children = { header }
    for _, item in ipairs(items) do
        table.insert(children, item)
    end

    return ui.column({
        gap = 6,
        fill = "horizontal",
        paddingH = 12,
        paddingV = 10,
        radius = 10,
        fill_color = "surface",
    }, children)
end

local function renderFlatpakSection()
    if not flatpak_installed then return nil end

    local count = getFlatpakCount()
    local has_updates = count > 0

    local header = ui.row({
        align = "center",
        gap = 8,
        fill = "horizontal",
    }, {
        ui.glyph({ name = "box", size = 16, color = "info" }),
        ui.label({
            text = "Flatpak",
            fontSize = 13,
            fontWeight = "bold",
            color = "on_surface",
            flexGrow = 1,
        }),
        ui.label({
            text = tostring(count) .. " update" .. (count ~= 1 and "s" or ""),
            fontSize = 12,
            color = has_updates and "info" or "success",
            fontWeight = "medium",
        }),
    })

    local items = {}
    if has_updates then
        local display_updates = flatpak_updates
        if not show_all_flatpak and #display_updates > 10 then
            local sliced = {}
            for i = 1, 10 do
                table.insert(sliced, display_updates[i])
            end
            display_updates = sliced
        end

        for _, pkg in ipairs(display_updates) do
            table.insert(items, ui.row({
                fill = "horizontal",
                paddingH = 8,
                paddingV = 4,
                radius = 6,
                align = "center",
                gap = 8,
            }, {
                ui.label({
                    text = pkg.name,
                    fontSize = 12,
                    color = "on_surface",
                    flexGrow = 1,
                    ellipsize = "end",
                }),
                ui.label({
                    text = pkg.version,
                    fontSize = 11,
                    color = "on_surface_variant",
                }),
            }))
        end

        if #flatpak_updates > 10 and not show_all_flatpak then
            table.insert(items, ui.button({
                label = "Show all " .. #flatpak_updates .. " packages",
                onClick = "onToggleShowAllFlatpak",
                size = "sm",
                fill = "horizontal",
            }))
        end
    else
        table.insert(items, ui.label({
            text = "All packages up to date",
            fontSize = 12,
            color = "success",
            alignment = "center",
            paddingH = 8,
            paddingV = 8,
        }))
    end

    local children = { header }
    for _, item in ipairs(items) do
        table.insert(children, item)
    end

    return ui.column({
        gap = 6,
        fill = "horizontal",
        paddingH = 12,
        paddingV = 10,
        radius = 10,
        fill_color = "surface",
    }, children)
end

render = function()
    local totalCount = getTotalCount()
    local hasUpdates = totalCount > 0

    local statusHero
    if checking then
        statusHero = ui.column({
            gap = 10,
            paddingH = 24,
            paddingV = 20,
            fill = "primary/0.08",
            radius = 16,
            align = "center",
        }, {
            ui.glyph({ name = "loader", size = 28, color = "primary" }),
            ui.label({ text = "Checking for updates...", color = "primary", fontWeight = "medium" }),
        })
    elseif hasUpdates then
        statusHero = ui.column({
            gap = 6,
            paddingH = 24,
            paddingV = 20,
            fill = "error/0.06",
            radius = 16,
            align = "center",
        }, {
            ui.label({
                text = tostring(totalCount),
                fontSize = 42,
                fontWeight = "bold",
                color = "error",
            }),
            ui.label({
                text = "update" .. (totalCount ~= 1 and "s" or "") .. " available",
                color = "on_surface_variant",
                fontSize = 13,
            }),
        })
    else
        statusHero = ui.column({
            gap = 8,
            paddingH = 24,
            paddingV = 20,
            fill = "success/0.06",
            radius = 16,
            align = "center",
        }, {
            ui.glyph({ name = "circle-check", size = 32, color = "success" }),
            ui.label({
                text = "System is up to date",
                color = "success",
                fontWeight = "medium",
                fontSize = 13,
            }),
        })
    end

    local searchInput = nil
    if hasUpdates then
        searchInput = ui.textinput({
            placeholder = "Search packages...",
            value = search_query,
            onChange = "onSearchChanged",
            fill = "horizontal",
            clearable = true,
            glyph = "search",
        })
    end

    local portageSection = renderPortageSection()
    local flatpakSection = renderFlatpakSection()

    local sections = {}
    table.insert(sections, portageSection)
    if flatpakSection then table.insert(sections, flatpakSection) end

    local body_children = {
        statusHero,
    }

    if searchInput then
        table.insert(body_children, searchInput)
    end

    for _, section in ipairs(sections) do
        table.insert(body_children, section)
    end

    local body = ui.column({
        gap = 12,
        flexGrow = 1,
    }, body_children)

    local footer = ui.row({
        gap = 8,
        fill = "horizontal",
        align = "center",
    }, {
        ui.label({
            text = "Last checked: " .. formatTimestamp(last_check),
            fontSize = 11,
            color = "on_surface_variant",
            flexGrow = 1,
        }),
        ui.button({
            label = "Check for Updates",
            onClick = "onCheckClicked",
            size = "sm",
            variant = "tonal",
        }),
        ui.button({
            label = "Update All",
            onClick = "onUpdateAllClicked",
            size = "sm",
            variant = "primary",
        }),
    })

    panel.render(ui.column({
        flexGrow = 1,
        gap = 16,
        padding = 16,
    }, {
        ui.row({
            align = "center",
            gap = 8,
            fill = "horizontal",
        }, {
            ui.glyph({ name = "refresh-cw", size = 18, color = "primary" }),
            ui.label({
                text = "System Updates",
                fontSize = 16,
                fontWeight = "bold",
                color = "on_surface",
                flexGrow = 1,
            }),
            ui.button({ glyph = "close", onClick = "onCloseClicked", size = "sm" }),
        }),
        ui.separator({}),
        ui.scroll({ flexGrow = 1 }, { body }),
        ui.separator({}),
        footer,
    }))
end

state.watch("checking", function(value)
    checking = value or false
    render()
end)

state.watch("last_check", function(value)
    last_check = value or 0
    render()
end)

state.watch("portage_updates", function(value)
    portage_updates = value or {}
    render()
end)

state.watch("flatpak_updates", function(value)
    flatpak_updates = value or {}
    render()
end)

state.watch("portage_available", function(value)
    portage_available = value or false
    render()
end)

state.watch("flatpak_installed", function(value)
    flatpak_installed = value or false
    render()
end)

render()
