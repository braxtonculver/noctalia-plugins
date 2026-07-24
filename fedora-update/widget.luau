local noctalia = noctalia
local state = noctalia.state

local function render()
    local checking = state.get("checking") or false
    local dnf_updates = state.get("dnf_updates") or {}
    local flatpak_updates = state.get("flatpak_updates") or {}

    local total = #dnf_updates + #flatpak_updates
    local has_updates = total > 0

    local badge = ""
    local color = "surface_variant"

    if checking then
        badge = "⟳"
        color = "primary"
    elseif has_updates then
        badge = tostring(total)
        color = "error"
    else
        badge = "✓"
        color = "success"
    end

    local row_children = {}
    if checking then
        table.insert(row_children, ui.glyph({ name = "loader", size = 14, color = color }))
    elseif has_updates then
        table.insert(row_children, ui.glyph({ name = "refresh-cw", size = 14, color = color }))
    end
    table.insert(row_children, ui.label({ text = badge, color = color, fontSize = 12, fontWeight = "bold" }))

    barWidget.render(
        ui.row({
            gap = 4,
            paddingH = 8,
            paddingV = 4,
            radius = 8,
            fill = color .. "/0.1",
            mainAxis = "center",
            crossAxis = "center",
        }, row_children)
    )
end

state.watch("checking", render)
state.watch("dnf_updates", render)
state.watch("flatpak_updates", render)

render()
