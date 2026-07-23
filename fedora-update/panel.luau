--!nonstrict
-- Updates panel: shows per-manager breakdowns (dnf, flatpak) with
-- packages listed under their respective sections and individual update buttons.
-- Communicates with the service through shared state.

local state = noctalia.state

local totalCount = 0
local dnfCount = 0
local flatpakCount = 0
local dnfPackages = {}
local flatpakPackages = {}
local lastChecked = nil
local isChecking = false
local errorMsg = nil
local flatpakInstalled = state.get("flatpak_installed")
local enableFlatpak = noctalia.getConfig("enable_flatpak")
if enableFlatpak == nil then enableFlatpak = true end
local showAll = false
local searchText = ""
local render -- forward declaration

state.watch("total_count", function(v)
    totalCount = v or 0
    render()
end)
state.watch("dnf_count", function(v)
    dnfCount = v or 0
    render()
end)
state.watch("flatpak_count", function(v)
    flatpakCount = v or 0
    render()
end)
state.watch("dnf_packages", function(v)
    dnfPackages = v or {}
    render()
end)
state.watch("flatpak_packages", function(v)
    flatpakPackages = v or {}
    render()
end)
state.watch("last_checked", function(v)
    lastChecked = v
    render()
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

    if #packages > 0 then
        for _, row in ipairs(buildPackageRows(packages, sourceLabel)) do
            table.insert(elements, row)
        end
    end

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

render = function()
    local hasUpdates = totalCount > 0

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

    local managerChildren = {}

    table.insert(managerChildren, managerSection(
        "DNF",
        dnfCount,
        "package",
        "tertiary",
        true,
        nil,
        "onUpdateDnf",
        dnfPackages,
        "dnf"
    ))

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

    local searchSection = nil
    if hasUpdates then
        searchSection = ui.input({
            key = "search",
            placeholder = noctalia.tr("panel.search"),
            controlSize = "sm",
            onChange = "onSearchChanged",
        })
    end

    local scrollChildren = { statusSection }
    if searchSection then
        table.insert(scrollChildren, searchSection)
    end
    table.insert(scrollChildren, managerSections)
    if errorSection then
        table.insert(scrollChildren, errorSection)
    end

    panel.render(ui.column({ flexGrow = 1, gap = 10 }, {
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

        ui.scroll({ flexGrow = 1, gap = 8 }, scrollChildren),

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
    dnfCount = state.get("dnf_count") or 0
    flatpakCount = state.get("flatpak_count") or 0
    dnfPackages = state.get("dnf_packages") or {}
    flatpakPackages = state.get("flatpak_packages") or {}
    lastChecked = state.get("last_checked")
    isChecking = state.get("checking") or false
    errorMsg = state.get("error")
    flatpakInstalled = state.get("flatpak_installed")
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

function onUpdateDnf()
    state.set("update_request", { command = "update_dnf", ts = os.time() })
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
    noctalia.log("Fedora Updater panel shutting down")
end
