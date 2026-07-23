--!nonstrict
-- Updates panel: shows per-manager breakdowns (pacman, AUR, flatpak) with
-- packages listed under their respective sections and individual update buttons.
-- Communicates with the service through shared state.

local state = noctalia.state

local totalCount = 0
local pacmanCount = 0
local aurCount = 0
local flatpakCount = 0
local pacmanPackages = {}
local aurPackages = {}
local flatpakPackages = {}
local lastChecked = nil
local isChecking = false
local errorMsg = nil
local aurHelper = state.get("aur_helper")
local flatpakInstalled = state.get("flatpak_installed")
local enableAur = noctalia.getConfig("enable_aur")
if enableAur == nil then enableAur = true end
local enableFlatpak = noctalia.getConfig("enable_flatpak")
if enableFlatpak == nil then enableFlatpak = true end
local showAll = false
local searchText = ""

state.watch("total_count", function(v)
    totalCount = v or 0
    render()
end)
state.watch("pacman_count", function(v)
    pacmanCount = v or 0
end)
state.watch("aur_count", function(v)
    aurCount = v or 0
end)
state.watch("flatpak_count", function(v)
    flatpakCount = v or 0
end)
state.watch("pacman_packages", function(v)
    pacmanPackages = v or {}
end)
state.watch("aur_packages", function(v)
    aurPackages = v or {}
end)
state.watch("flatpak_packages", function(v)
    flatpakPackages = v or {}
end)
state.watch("last_checked", function(v)
    lastChecked = v
end)
state.watch("checking", function(v)
    isChecking = v or false
    render()
end)
state.watch("error", function(v)
    errorMsg = v
    render()
end)

local function formatTime(unixTime)
    if unixTime == nil then
        return noctalia.tr("panel.never_checked")
    end
    return noctalia.tr("panel.last_checked", { time = noctalia.formatTime("%H:%M", unixTime) })
end

local function searchMatch(text)
    if searchText == "" then
        return true
    end
    return string.find(text:lower(), searchText:lower(), 1, true) ~= nil
end

local function buildPackageRows(packages, sourceLabel)
    local elements = {}
    local maxDisplay = showAll and #packages or math.min(50, #packages)
    local visibleCount = 0

    for i = 1, maxDisplay do
        local pkg = packages[i]
        if searchMatch(pkg.name) then
            visibleCount += 1
            table.insert(elements, ui.row({
                key = sourceLabel .. "-" .. pkg.name,
                paddingH = 10,
                paddingV = 3,
                radius = 4,
                fill = "surface_container_low",
            }, {
                ui.label({
                    text = pkg.name,
                    fontSize = 11,
                    color = "on_surface",
                    flexGrow = 1,
                    maxLines = 1,
                }),
                ui.label({
                    text = pkg.version,
                    fontSize = 10,
                    color = "on_surface_variant",
                }),
            }))
        end
    end

    if not showAll and #packages > 50 then
        table.insert(elements, ui.button({
            text = noctalia.tr("panel.show_all"),
            variant = "ghost",
            onClick = "onShowAll",
        }))
    end

    if visibleCount == 0 and searchText ~= "" then
        table.insert(elements, ui.label({
            text = noctalia.tr("panel.no_results"),
            fontSize = 11,
            color = "on_surface_variant",
            paddingV = 4,
        }))
    end

    return elements
end

local function managerSection(title, count, glyph, color, hasHelper, disabledLabel, updateEvent, packages, sourceLabel)
    local elements = {}

    -- Section header row
    table.insert(elements, ui.row({
        align = "center",
        gap = 8,
    }, {
        ui.glyph({
            name = glyph,
            size = 16,
            color = color,
        }),
        ui.label({
            text = title,
            fontWeight = "bold",
            color = "on_surface",
            flexGrow = 1,
        }),
        ui.label({
            text = count > 0
                and noctalia.tr("panel.packages_count", { count = tostring(count) })
                or (disabledLabel or noctalia.tr("panel.up_to_date")),
            fontSize = 11,
            color = count > 0 and "on_surface_variant" or "success",
        }),
    }))

    -- Package list (only if there are packages)
    if #packages > 0 then
        for _, row in ipairs(buildPackageRows(packages, sourceLabel)) do
            table.insert(elements, row)
        end
    end

    -- Update button (only if helper exists and there are updates)
    if hasHelper and count > 0 then
        table.insert(elements, ui.button({
            text = noctalia.tr("panel.update"),
            variant = "primary",
            controlSize = "sm",
            onClick = updateEvent,
        }))
    elseif not hasHelper then
        table.insert(elements, ui.button({
            text = disabledLabel or "N/A",
            variant = "ghost",
            controlSize = "sm",
            enabled = false,
        }))
    end

    return ui.column({
        gap = 8,
        paddingH = 12,
        paddingV = 10,
        fill = "surface_container",
        radius = 12,
    }, elements)
end

local function render()
    local hasUpdates = totalCount > 0

    -- Status section
    local statusSection
    if isChecking then
        statusSection = ui.column({
            gap = 10,
            paddingH = 20,
            paddingV = 16,
            fill = "primary/0.1",
            radius = 16,
            align = "center",
        }, {
            ui.glyph({
                name = "loader",
                size = 24,
                color = "primary",
            }),
            ui.label({
                text = noctalia.tr("panel.checking"),
                color = "primary",
                fontWeight = "medium",
            }),
        })
    elseif hasUpdates then
        statusSection = ui.column({
            gap = 8,
            paddingH = 20,
            paddingV = 16,
            fill = "error/0.08",
            radius = 16,
            align = "center",
        }, {
            ui.label({
                text = tostring(totalCount),
                fontSize = 36,
                fontWeight = "bold",
                color = "error",
            }),
            ui.label({
                text = noctalia.tr("panel.updates_available"),
                color = "on_surface_variant",
            }),
        })
    else
        statusSection = ui.column({
            gap = 8,
            paddingH = 20,
            paddingV = 16,
            fill = "success/0.08",
            radius = 16,
            align = "center",
        }, {
            ui.glyph({
                name = "circle-check",
                size = 28,
                color = "success",
            }),
            ui.label({
                text = noctalia.tr("panel.up_to_date"),
                color = "success",
                fontWeight = "medium",
            }),
        })
    end

    -- Manager sections (each with its own package list)
    local managerChildren = {}

    -- Pacman section (always shown)
    table.insert(managerChildren, managerSection(
        "Pacman",
        pacmanCount,
        "package",
        "tertiary",
        true,
        nil,
        "onUpdatePacman",
        pacmanPackages,
        "pacman"
    ))

    -- AUR section (only if enabled)
    if enableAur then
        local helperLabel = aurHelper
            and noctalia.tr("panel.update_with") .. " " .. aurHelper
            or noctalia.tr("panel.no_helper")
        table.insert(managerChildren, managerSection(
            "AUR" .. (aurHelper and (" (" .. aurHelper .. ")") or ""),
            aurCount,
            "building-community",
            "primary",
            aurHelper ~= nil,
            helperLabel,
            "onUpdateAur",
            aurPackages,
            "aur"
        ))
    end

    -- Flatpak section (only if enabled)
    if enableFlatpak then
        table.insert(managerChildren, managerSection(
            "Flatpak",
            flatpakCount,
            "brand-flutter",
            "secondary",
            flatpakInstalled,
            noctalia.tr("panel.not_installed"),
            "onUpdateFlatpak",
            flatpakPackages,
            "flatpak"
        ))
    end

    local managerSections = ui.column({ gap = 8 }, managerChildren)

    -- Error section
    local errorSection = nil
    if errorMsg and errorMsg ~= "" then
        errorSection = ui.row({
            paddingH = 12,
            paddingV = 8,
            fill = "error/0.1",
            radius = 8,
            align = "center",
            gap = 8,
        }, {
            ui.glyph({
                name = "alert-triangle",
                size = 14,
                color = "error",
            }),
            ui.label({
                text = errorMsg,
                fontSize = 11,
                color = "error",
                flexGrow = 1,
                maxLines = 2,
            }),
        })
    end

    -- Search input (only if there are updates)
    local searchSection = nil
    if hasUpdates then
        searchSection = ui.input({
            placeholder = noctalia.tr("panel.search"),
            controlSize = "sm",
            onChange = "onSearchChanged",
        })
    end

    -- Assemble the full panel
    panel.render(ui.column({ flexGrow = 1, gap = 10 }, {
        -- Header
        ui.row({ align = "center", justify = "space_between", gap = 8 }, {
            ui.label({
                text = noctalia.tr("panel.title"),
                fontSize = 16,
                fontWeight = "bold",
                color = "on_surface",
                flexGrow = 1,
            }),
            ui.button({
                text = isChecking and noctalia.tr("panel.checking") or noctalia.tr("panel.refresh"),
                variant = "ghost",
                controlSize = "sm",
                onClick = "onRefreshClicked",
            }),
            ui.button({ glyph = "close", onClick = "onCloseClicked" }),
        }),

        -- Scrollable body
        ui.scroll({ flexGrow = 1, gap = 8 }, {
            statusSection,
            searchSection or ui.column({}),
            managerSections,
            errorSection or ui.column({}),
        }),

        -- Footer
        ui.row({ align = "center", justify = "space_between", gap = 8 }, {
            ui.label({
                text = formatTime(lastChecked),
                fontSize = 10,
                color = "on_surface_variant",
                flexGrow = 1,
            }),
            ui.button({
                text = hasUpdates
                    and noctalia.tr("panel.update_all") .. " (" .. tostring(totalCount) .. ")"
                    or noctalia.tr("panel.update_all"),
                variant = hasUpdates and "primary" or "ghost",
                onClick = "onUpdateAll",
            }),
        }),
    }))
end

function onOpen(_context)
    totalCount = state.get("total_count") or 0
    pacmanCount = state.get("pacman_count") or 0
    aurCount = state.get("aur_count") or 0
    flatpakCount = state.get("flatpak_count") or 0
    pacmanPackages = state.get("pacman_packages") or {}
    aurPackages = state.get("aur_packages") or {}
    flatpakPackages = state.get("flatpak_packages") or {}
    lastChecked = state.get("last_checked")
    isChecking = state.get("checking") or false
    errorMsg = state.get("error")
    aurHelper = state.get("aur_helper")
    flatpakInstalled = state.get("flatpak_installed")
    enableAur = noctalia.getConfig("enable_aur")
    if enableAur == nil then enableAur = true end
    enableFlatpak = noctalia.getConfig("enable_flatpak")
    if enableFlatpak == nil then enableFlatpak = true end
    showAll = false
    searchText = ""
    render()
end

function onRefreshClicked()
    isChecking = true
    render()
    state.set("refresh_request", os.time())
end

function onUpdatePacman()
    state.set("update_request", { command = "update_pacman", ts = os.time() })
end

function onUpdateAur()
    state.set("update_request", { command = "update_aur", ts = os.time() })
end

function onUpdateFlatpak()
    state.set("update_request", { command = "update_flatpak", ts = os.time() })
end

function onUpdateAll()
    state.set("update_request", { command = "update_all", ts = os.time() })
end

function onShowAll()
    showAll = true
    render()
end

function onSearchChanged(value)
    searchText = value or ""
    render()
end

function onCloseClicked()
    panel.close()
end

function onExit(_signal)
    noctalia.log("Arch Updater panel shutting down")
end
