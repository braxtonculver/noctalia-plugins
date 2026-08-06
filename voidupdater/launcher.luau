--!nonstrict
-- void-updater launcher provider, under the `/void` prefix.
--
-- Empty query shows the two quick actions. Any other text is fuzzy-matched
-- against the pending packages from the last check, read straight from the
-- shared "void_state" the engine publishes. Activating a package opens its
-- page, same as the panel's "open" button on a package row.

local STATE_KEY = "void_state"
local REQUEST_KEY = "void_request"

local function tr(key, args)
    return noctalia.tr(key, args)
end

local function request(action)
    local prev = noctalia.state.get(REQUEST_KEY)
    local nonce = (type(prev) == "table" and tonumber(prev.nonce) or 0) + 1
    noctalia.state.set(REQUEST_KEY, { nonce = nonce, action = action })
end

local function shellQuote(value)
    return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function openUrl(url)
    if noctalia.commandExists("xdg-open") then
        noctalia.runAsync("xdg-open " .. shellQuote(url) .. " >/dev/null 2>&1")
    end
end

local SOURCE_GLYPH = { xbps = "package", flatpak = "app-window" }

local function packageUrl(sourceKey, name)
    if sourceKey == "xbps" then
        return "https://voidlinux.org/packages/?q=" .. noctalia.string.urlEncode(name)
    end
    return "https://flathub.org/apps/" .. noctalia.string.urlEncode(name)
end

local function commandResults()
    return {
        { id = "cmd-check", title = tr("action_check"), subtitle = tr("launcher.check_subtitle"), glyph = "refresh" },
        { id = "cmd-update", title = tr("action_update"), subtitle = tr("launcher.update_subtitle"), glyph = "download" },
    }
end

local function packageResults(query)
    local state = noctalia.state.get(STATE_KEY)
    if type(state) ~= "table" then
        return {}
    end

    local results = {}
    local sourceList = { { key = "xbps", entry = state.xbps }, { key = "flatpak", entry = state.flatpak } }
    for _, source in ipairs(sourceList) do
        local items = type(source.entry) == "table" and source.entry.items or nil
        if type(items) == "table" then
            for _, item in ipairs(items) do
                local score = noctalia.fuzzyScore(query, item.name)
                if score ~= nil then
                    local subtitle
                    if item.to ~= nil and item.to ~= "" then
                        subtitle = (item.from ~= nil and item.from ~= "")
                            and (item.from .. " → " .. item.to)
                            or ("→ " .. item.to)
                    else
                        subtitle = tr("source." .. source.key)
                    end
                    table.insert(results, {
                        id = "pkg-" .. source.key .. "-" .. item.name,
                        title = item.name,
                        subtitle = subtitle,
                        glyph = SOURCE_GLYPH[source.key] or "package",
                        score = score,
                    })
                end
            end
        end
    end
    return results
end

function onQuery(query)
    if query == "" then
        launcher.setResults(query, commandResults())
        return
    end
    launcher.setResults(query, packageResults(query))
end

function onActivate(id)
    if id == "cmd-check" then
        request("check")
    elseif id == "cmd-update" then
        request("update")
    else
        local sourceKey, name = id:match("^pkg%-([a-z]+)%-(.+)$")
        if sourceKey ~= nil and name ~= nil then
            openUrl(packageUrl(sourceKey, name))
        end
    end
end
