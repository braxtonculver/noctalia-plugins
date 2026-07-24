--!nonstrict
-- Fedora Linux updater bar widget.
-- Shows update count badge, opens panel on click.

local checking = false
local dnf_updates = {}
local flatpak_updates = {}

local function getTotalCount()
    return #dnf_updates + #flatpak_updates
end

local function render()
    local total = getTotalCount()
    local has_updates = total > 0

    if checking then
        barWidget.setGlyph("loader")
        barWidget.setText("...")
    elseif has_updates then
        barWidget.setGlyph("refresh-cw")
        barWidget.setText(tostring(total))
    else
        barWidget.setGlyph("check")
        barWidget.setText("")
    end
end

noctalia.state.watch("checking", function(value)
    checking = value or false
    render()
end)

noctalia.state.watch("dnf_updates", function(value)
    dnf_updates = value or {}
    render()
end)

noctalia.state.watch("flatpak_updates", function(value)
    flatpak_updates = value or {}
    render()
end)

function update()
    noctalia.setUpdateInterval(1000)
    render()
end

function onClick()
    noctalia.togglePanel("braxtonculver/fedora-update:updates")
end
