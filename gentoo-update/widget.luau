--!nonstrict
-- Bar widget: shows the total number of available updates as a badge next to
-- a customizable glyph. Uses declarative ui.* rendering. Clicking the widget
-- opens the updates panel.

local updateGlyph = noctalia.getConfig("icon_glyph") or "refresh"
local showCount = noctalia.getConfig("show_count")
if showCount == nil then
    showCount = true
end

local totalCount = noctalia.state.get("total_count") or 0
local isChecking = noctalia.state.get("checking") or false
local hasError = noctalia.state.get("error") ~= nil

local function render()
    local container = barWidget.isVertical() and ui.column or ui.row
    local elements = {}

    local glyphColor = "primary"
    if hasError then
        glyphColor = "error"
    elseif totalCount > 0 then
        glyphColor = "warning"
    end

    table.insert(elements, ui.glyph({
        name = updateGlyph,
        size = 14,
        color = glyphColor,
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

    if hasError then
        barWidget.setTooltip(noctalia.tr("widget.error"))
    elseif totalCount > 0 then
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

noctalia.state.watch("error", function(value)
    hasError = value ~= nil and value ~= ""
    render()
end)

function update()
    noctalia.setUpdateInterval(5000)
    render()
end

function onClick()
    noctalia.togglePanel("braxtonculver/gentoo-update:updates")
end

function onExit(_signal)
    noctalia.log("Gentoo Updater widget shutting down")
end
