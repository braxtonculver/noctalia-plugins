--!nonstrict
-- Bar widget: shows the total number of available updates as a badge next to
-- a system glyph. Uses declarative ui.* rendering. Clicking the widget opens
-- the updates panel.

local showCount = noctalia.getConfig("show_count")
if showCount == nil then
    showCount = true
end

local totalCount = noctalia.state.get("total_count") or 0
local isChecking = noctalia.state.get("checking") or false

local function render()
    local container = barWidget.isVertical() and ui.column or ui.row
    local elements = {}

    table.insert(elements, ui.glyph({
        name = "system",
        size = 14,
        color = "primary",
    }))

    if totalCount > 0 and showCount then
        table.insert(elements, ui.row({
            fill = "error/0.25",
            radius = 8,
            paddingH = 6,
            align = "center",
        }, {
            ui.label({
                text = tostring(totalCount),
                color = "error",
                fontWeight = "bold",
            }),
        }))
    elseif isChecking then
        table.insert(elements, ui.label({
            text = "...",
            color = "on_surface_variant",
        }))
    end

    barWidget.render(container({
        gap = 6,
        align = "center",
    }, elements))

    if totalCount > 0 then
        barWidget.setTooltip(noctalia.tr("widget.updates_available", { count = totalCount }))
    else
        barWidget.setTooltip(noctalia.tr("widget.up_to_date"))
    end
end

noctalia.state.watch("total_count", function(value)
    totalCount = value or 0
    render()
end)

noctalia.state.watch("checking", function(value)
    isChecking = value or false
    render()
end)

function update()
    noctalia.setUpdateInterval(5000)
    render()
end

function onClick()
    noctalia.togglePanel("braxtonculver/updater:updates")
end

function onExit(_signal)
    noctalia.log("Arch Updater widget shutting down")
end
