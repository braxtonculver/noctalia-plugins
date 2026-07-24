--!nonstrict
-- openSUSE updater panel.
-- Shows update status, package lists per manager, and update actions.

local state = noctalia.state
local panel = noctalia.panel

local zypper_updates = {}
local flatpak_updates = {}
local zypper_available = false
local flatpak_installed = false
local checking = false
local last_check = 0
local search_query = ""
local show_all_zypper = false
local show_all_flatpak = false

local function formatTimestamp(ts)
    if ts == 0 then return "Never" end
    return noctalia.formatTime(ts, "%H:%M")
end

local function getTotalCount()
    return #zypper_updates + #flatpak_updates
end

local function renderManagerSection(name, glyph_name, color, updates, show_all, toggle_fn, search)
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

    local header = ui.row({
        align = "center",
        gap = 8,
        fill = "horizontal",
    }, {
        ui.glyph({ name = glyph_name, size = 16, color = color }),
        ui.label({
            text = name,
            fontSize = 13,
            fontWeight = "bold",
            color = "on_surface",
            flexGrow = 1,
        }),
        ui.label({
            text = tostring(count) .. " update" .. (count ~= 1 and "s" or ""),
            fontSize = 12,
            color = has_updates and color or "success",
            fontWeight = "medium",
        }),
    })

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
            table.insert(rows, ui.row({
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
                }),
                ui.label({
                    text = pkg.version,
                    fontSize = 11,
                    color = "on_surface_variant",
                }),
            }))
        end

        if #filtered > 10 and not show_all then
            table.insert(rows, ui.button({
                text = "Show all " .. #filtered,
                onClick = toggle_fn,
                variant = "ghost",
            }))
        end
    else
        table.insert(rows, ui.label({
            text = "All packages up to date",
            fontSize = 12,
            color = "success",
        }))
    end

    local children = { header }
    for _, row in ipairs(rows) do
        table.insert(children, row)
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

local function render()
    local total = getTotalCount()
    local has_updates = total > 0

    local status_hero
    if checking then
        status_hero = ui.column({
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
    elseif has_updates then
        status_hero = ui.column({
            gap = 6,
            paddingH = 24,
            paddingV = 20,
            fill = "error/0.06",
            radius = 16,
            align = "center",
        }, {
            ui.label({
                text = tostring(total),
                fontSize = 42,
                fontWeight = "bold",
                color = "error",
            }),
            ui.label({
                text = "update" .. (total ~= 1 and "s" or "") .. " available",
                color = "on_surface_variant",
                fontSize = 13,
            }),
        })
    else
        status_hero = ui.column({
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

    local sections = {}

    table.insert(sections, renderManagerSection(
        "Zypper", "package", "primary",
        zypper_updates, show_all_zypper, "onToggleShowAllZypper", search_query
    ))

    if flatpak_installed then
        table.insert(sections, renderManagerSection(
            "Flatpak", "box", "info",
            flatpak_updates, show_all_flatpak, "onToggleShowAllFlatpak", search_query
        ))
    end

    local body_children = { status_hero }
    if has_updates then
        table.insert(body_children, ui.input({
            key = "search",
            placeholder = "Search packages...",
            value = search_query,
            onChange = "onSearchChanged",
        }))
    end
    for _, s in ipairs(sections) do
        table.insert(body_children, s)
    end

    panel.render(ui.column({ flexGrow = 1, gap = 16 }, {
        ui.row({ align = "center", justify = "space_between", gap = 8 }, {
            ui.glyph({ name = "refresh-cw", size = 18, color = "primary" }),
            ui.label({
                text = "System Updates",
                fontSize = 16,
                fontWeight = "bold",
                color = "on_surface",
                flexGrow = 1,
            }),
            ui.button({ glyph = "close", onClick = "onCloseClicked" }),
        }),

        ui.scroll({ flexGrow = 1, gap = 12 }, body_children),

        ui.row({ gap = 8, align = "center" }, {
            ui.label({
                text = "Last checked: " .. formatTimestamp(last_check),
                fontSize = 11,
                color = "on_surface_variant",
                flexGrow = 1,
            }),
            ui.button({ text = "Check", onClick = "onCheckClicked", variant = "secondary" }),
            ui.button({ text = "Update All", onClick = "onUpdateAllClicked", variant = "primary" }),
        }),
    }))
end

function onOpen(_context)
    zypper_updates = state.get("zypper_updates") or {}
    flatpak_updates = state.get("flatpak_updates") or {}
    zypper_available = state.get("zypper_available") or false
    flatpak_installed = state.get("flatpak_installed") or false
    checking = state.get("checking") or false
    last_check = state.get("last_check") or 0
    render()
end

state.watch("checking", function(value)
    checking = value or false
    render()
end)

state.watch("last_check", function(value)
    last_check = value or 0
    render()
end)

state.watch("zypper_updates", function(value)
    zypper_updates = value or {}
    render()
end)

state.watch("flatpak_updates", function(value)
    flatpak_updates = value or {}
    render()
end)

state.watch("zypper_available", function(value)
    zypper_available = value or false
    render()
end)

state.watch("flatpak_installed", function(value)
    flatpak_installed = value or false
    render()
end)

function onCloseClicked()
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

function onToggleShowAllZypper()
    show_all_zypper = not show_all_zypper
    render()
end

function onToggleShowAllFlatpak()
    show_all_flatpak = not show_all_flatpak
    render()
end
