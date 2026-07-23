--!nonstrict
-- Updates panel: shows per-manager breakdowns (pacman, AUR, flatpak) with
-- individual update buttons and a combined "Update All" action. Refreshes
-- via IPC when the service completes a check or update.

local state = noctalia.state

local function formatTime(unixTime)
    if unixTime == nil then
        return noctalia.tr("panel.never_checked")
    end
    return noctalia.tr("panel.last_checked", { time = noctalia.formatTime("%H:%M", unixTime) })
end

local function sectionHeading(text)
    return ui.row({
        paddingH = 4,
        paddingV = 8,
    }, {
        ui.label({
            text = text,
            fontSize = 12,
            fontWeight = "bold",
            color = "on_surface_variant",
        }),
    })
end

local function packageRow(title, count, hasHelper, helperLabel, updateEvent, isFlatpak)
    local elements = {}

    table.insert(elements, ui.column({
        flexGrow = 1,
        gap = 2,
    }, {
        ui.label({
            text = title,
            fontWeight = "medium",
            color = "on_surface",
        }),
        ui.label({
            text = string.format("%d packages", count),
            fontSize = 11,
            color = "on_surface_variant",
        }),
    }))

    if (hasHelper ~= false) and count > 0 then
        table.insert(elements, ui.button({
            text = "Update",
            variant = "primary",
            onClick = updateEvent,
        }))
    elseif hasHelper == false then
        table.insert(elements, ui.label({
            text = helperLabel or "N/A",
            fontSize = 11,
            color = "on_surface_variant",
        }))
    else
        table.insert(elements, ui.label({
            text = "Up to date",
            fontSize = 11,
            color = "success",
        }))
    end

    return ui.row({
        paddingH = 12,
        paddingV = 10,
        fill = "surface_container",
        radius = 8,
        align = "center",
    }, elements)
end

local function render()
    local pacmanCount = state.get("pacman_count") or 0
    local aurCount = state.get("aur_count") or 0
    local flatpakCount = state.get("flatpak_count") or 0
    local totalCount = state.get("total_count") or 0
    local lastChecked = state.get("last_checked")
    local aurHelper = state.get("aur_helper")
    local flatpakInstalled = state.get("flatpak_installed")
    local isChecking = state.get("checking") or false

    local hasUpdates = totalCount > 0

    panel.render(ui.column({
        flexGrow = 1,
        gap = 0,
    }, {
        -- Header
        ui.row({
            paddingH = 16,
            paddingV = 12,
            align = "center",
        }, {
            ui.label({
                text = "System Updates",
                fontSize = 16,
                fontWeight = "bold",
                color = "on_surface",
                flexGrow = 1,
            }),
            ui.button({
                glyph = "close",
                variant = "ghost",
                onClick = "onCloseClicked",
            }),
        }),

        -- Subheader with check info and refresh
        ui.row({
            paddingH = 16,
            paddingV = 8,
            align = "center",
        }, {
            ui.label({
                text = formatTime(lastChecked),
                fontSize = 11,
                color = "on_surface_variant",
                flexGrow = 1,
            }),
            ui.button({
                text = isChecking and "Checking..." or "Refresh",
                variant = "ghost",
                onClick = "onRefreshClicked",
            }),
        }),

        -- Total summary badge
        ui.row({
            paddingH = 16,
            paddingV = 8,
        }, {
            ui.row({
                fill = hasUpdates and "error/0.15" or "success/0.15",
                radius = 12,
                paddingH = 16,
                paddingV = 10,
                align = "center",
            }, {
                ui.glyph({
                    name = hasUpdates and "system" or "check",
                    size = 18,
                    color = hasUpdates and "error" or "success",
                }),
                ui.label({
                    text = hasUpdates
                        and string.format("%d packages need updating", totalCount)
                        or "System is up to date",
                    fontWeight = "medium",
                    color = hasUpdates and "error" or "success",
                    marginLeft = 8,
                }),
            }),
        }),

        -- Package manager sections
        ui.scroll({
            flexGrow = 1,
            gap = 8,
            paddingH = 16,
            paddingV = 8,
        }, {
            sectionHeading("PACMAN"),
            packageRow(
                "Pacman",
                pacmanCount,
                true,
                nil,
                "onUpdatePacman",
                false
            ),

            sectionHeading("AUR"),
            packageRow(
                "AUR (" .. (aurHelper or "none") .. ")",
                aurCount,
                aurHelper ~= nil,
                "No AUR helper found",
                "onUpdateAur",
                false
            ),

            sectionHeading("FLATPAK"),
            packageRow(
                "Flatpak",
                flatpakCount,
                flatpakInstalled,
                "Flatpak not installed",
                "onUpdateFlatpak",
                true
            ),
        }),

        -- Footer with Update All button
        ui.row({
            paddingH = 16,
            paddingV = 12,
            fill = "surface_container",
            radius = 0,
            align = "center",
        }, {
            ui.button({
                text = hasUpdates and string.format("Update All (%d)", totalCount) or "Update All",
                variant = hasUpdates and "primary" or "ghost",
                onClick = "onUpdateAllClicked",
                flexGrow = 1,
            }),
        }),
    }))
end

function onOpen(_context)
    render()
end

function onRefreshClicked()
    state.set("checking", true)
    render()
    noctalia.runInTerminal("noctalia msg plugin braxton/updater:checker all check")
    noctalia.runAsync("sleep 10", function()
        render()
    end)
end

function onUpdatePacmanClicked()
    noctalia.runInTerminal("noctalia msg plugin braxton/updater:checker all update_pacman")
    noctalia.notify("Pacman", "Starting pacman update...")
    noctalia.runAsync("sleep 5", function()
        render()
    end)
end

function onUpdateAurClicked()
    noctalia.runInTerminal("noctalia msg plugin braxton/updater:checker all update_aur")
    noctalia.notify("AUR", "Starting AUR update...")
    noctalia.runAsync("sleep 5", function()
        render()
    end)
end

function onUpdateFlatpakClicked()
    noctalia.runInTerminal("noctalia msg plugin braxton/updater:checker all update_flatpak")
    noctalia.notify("Flatpak", "Starting flatpak update...")
    noctalia.runAsync("sleep 5", function()
        render()
    end)
end

function onUpdateAllClicked()
    noctalia.runInTerminal("noctalia msg plugin braxton/updater:checker all update_all")
    noctalia.notify("Updates", "Starting full system update...")
    noctalia.runAsync("sleep 8", function()
        render()
    end)
end

function onCloseClicked()
    panel.close()
end

function onIpc(event, _payload)
    if event == "recheck_done" then
        render()
    end
end

function onExit(_signal)
    noctalia.log("Arch Updater panel shutting down")
end
