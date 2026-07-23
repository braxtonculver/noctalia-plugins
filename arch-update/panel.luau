--!nonstrict
-- Updates panel: shows per-manager breakdowns (pacman, AUR, flatpak) with
-- package lists, individual update buttons, and a combined "Update All" action.
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
end)
state.watch("error", function(v)
    errorMsg = v
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

local function buildPackageList(packages, sourceLabel, color)
    local elements = {}
    local count = 0
    local maxDisplay = showAll and #packages or math.min(50, #packages)

    for i = 1, maxDisplay do
        local pkg = packages[i]
        if searchMatch(pkg.name) then
            count += 1
            table.insert(elements, ui.row({
                key = sourceLabel .. "-" .. pkg.name,
                paddingH = 10,
                paddingV = 4,
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
        table.insert(elements, ui.row({
            paddingH = 10,
            paddingV = 6,
        }, {
            ui.button({
                text = noctalia.tr("panel.show_all"),
                variant = "ghost",
                onClick = "onShowAll",
            }),
        }))
    end

    if count == 0 and searchText ~= "" then
        table.insert(elements, ui.row({
            paddingH = 10,
            paddingV = 12,
        }, {
            ui.label({
                text = noctalia.tr("panel.no_results"),
                fontSize = 11,
                color = "on_surface_variant",
            }),
        }))
    end

    return elements
end

local function managerCard(title, count, glyph, color, hasHelper, helperLabel, updateEvent)
    local elements = {}

    table.insert(elements, ui.row({
        align = "center",
        gap = 10,
    }, {
        ui.glyph({
            name = glyph,
            size = 18,
            color = color,
        }),
        ui.column({
            flexGrow = 1,
            gap = 2,
        }, {
            ui.label({
                text = title,
                fontWeight = "bold",
                color = "on_surface",
            }),
            ui.label({
                text = count > 0
                    and noctalia.tr("panel.packages_count", { count = tostring(count) })
                    or (helperLabel or noctalia.tr("panel.up_to_date")),
                fontSize = 11,
                color = count > 0 and "on_surface_variant" or "success",
            }),
        }),
    }))

    if hasHelper and count > 0 then
        table.insert(elements, ui.button({
            text = noctalia.tr("panel.update"),
            variant = "primary",
            controlSize = "sm",
            onClick = updateEvent,
        }))
    elseif not hasHelper then
        table.insert(elements, ui.button({
            text = helperLabel or "N/A",
            variant = "ghost",
            controlSize = "sm",
            enabled = false,
        }))
    end

    return ui.column({
        gap = 10,
        paddingH = 12,
        paddingV = 10,
        fill = "surface_container",
        radius = 12,
    }, elements)
end

local function render()
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
                text = noctalia.tr("panel.up_to_date_message"),
                color = "success",
                fontWeight = "medium",
            }),
        })
    end

    local managerCards = ui.column({
        gap = 8,
    }, {
        managerCard(
            "Pacman",
            pacmanCount,
            "package",
            "tertiary",
            true,
            nil,
            "onUpdatePacman"
        ),
        managerCard(
            "AUR (" .. (aurHelper or "none") .. ")",
            aurCount,
            "building-community",
            "primary",
            aurHelper ~= nil,
            noctalia.tr("panel.no_helper"),
            "onUpdateAur"
        ),
        managerCard(
            "Flatpak",
            flatpakCount,
            "brand-flutter",
            "secondary",
            flatpakInstalled,
            noctalia.tr("panel.not_installed"),
            "onUpdateFlatpak"
        ),
    })

    local packageListSection = ui.column({ gap = 0 }, {})
    if hasUpdates then
        local allPackages = {}
        for _, pkg in ipairs(pacmanPackages) do
            table.insert(allPackages, pkg)
        end
        for _, pkg in ipairs(aurPackages) do
            table.insert(allPackages, pkg)
        end
        for _, pkg in ipairs(flatpakPackages) do
            table.insert(allPackages, pkg)
        end

        if #allPackages > 0 then
            local packageElements = {}
            if #pacmanPackages > 0 then
                local pkgs = buildPackageList(pacmanPackages, "pacman", "tertiary")
                for _, el in ipairs(pkgs) do
                    table.insert(packageElements, el)
                end
            end
            if #aurPackages > 0 then
                local pkgs = buildPackageList(aurPackages, "aur", "primary")
                for _, el in ipairs(pkgs) do
                    table.insert(packageElements, el)
                end
            end
            if #flatpakPackages > 0 then
                local pkgs = buildPackageList(flatpakPackages, "flatpak", "secondary")
                for _, el in ipairs(pkgs) do
                    table.insert(packageElements, el)
                end
            end

            packageListSection = ui.column({
                gap = 6,
            }, {
                ui.input({
                    placeholder = noctalia.tr("panel.search"),
                    controlSize = "sm",
                    onChange = "onSearchChanged",
                }),
                ui.scroll({
                    gap = 2,
                    maxHeight = 140,
                    fill = "surface_container_low",
                    radius = 8,
                    padding = 4,
                }, packageElements),
            })
        end
    end

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

    local children = {
        -- Header
        ui.row({
            paddingH = 16,
            paddingV = 12,
            align = "center",
        }, {
            ui.label({
                text = noctalia.tr("panel.title"),
                fontSize = 16,
                fontWeight = "bold",
                color = "on_surface",
                flexGrow = 1,
            }),
            ui.glyph({
                name = "refresh",
                size = 14,
                color = isChecking and "primary" or "on_surface_variant",
            }),
            ui.button({
                text = isChecking and noctalia.tr("panel.checking") or noctalia.tr("panel.refresh"),
                variant = "ghost",
                controlSize = "sm",
                onClick = "onRefreshClicked",
            }),
            ui.button({
                glyph = "x",
                variant = "ghost",
                onClick = "onCloseClicked",
            }),
        }),

        -- Status
        ui.column({
            paddingH = 16,
            gap = 0,
        }, { statusSection }),

        -- Manager cards
        ui.column({
            paddingH = 16,
            gap = 8,
        }, { managerCards }),

        -- Package list
        ui.column({
            paddingH = 16,
            flexGrow = 1,
            gap = 0,
        }, { packageListSection }),

        -- Error
        errorSection and ui.column({
            paddingH = 16,
            gap = 0,
        }, { errorSection }) or ui.column({}),

        -- Footer
        ui.row({
            paddingH = 16,
            paddingV = 12,
            align = "center",
        }, {
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
    }

    panel.render(ui.column({
        flexGrow = 1,
        gap = 8,
    }, children))
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
    showAll = false
    searchText = ""
    render()
end

function onRefreshClicked()
    state.set("checking", true)
    isChecking = true
    render()
    noctalia.runAsync("noctalia msg plugin braxtonculver/arch-update:checker all check")
end

function onUpdatePacman()
    noctalia.runAsync("noctalia msg plugin braxtonculver/arch-update:checker all update_pacman")
end

function onUpdateAur()
    noctalia.runAsync("noctalia msg plugin braxtonculver/arch-update:checker all update_aur")
end

function onUpdateFlatpak()
    noctalia.runAsync("noctalia msg plugin braxtonculver/arch-update:checker all update_flatpak")
end

function onUpdateAll()
    noctalia.runAsync("noctalia msg plugin braxtonculver/arch-update:checker all update_all")
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
