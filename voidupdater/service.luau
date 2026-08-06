--!nonstrict
-- void-updater singleton engine. Checks xbps and Flatpak, publishes the result
-- as shared state, and runs the update in a terminal.
--
--   state    "void_state"   = { nonce, phase, step, total, xbps, flatpak,
--                                rebootRecommended, dismissed, err,
--                                checkedAt, ignoredCount, flatpakEnabled }
--   requests "void_request" = { nonce, action }  -- check|update|dismiss
--
-- Checking runs xbps, then Flatpak, then a reboot probe.
--
-- Update never runs in the background. runUpdate() opens a terminal so
-- xbps can prompt and sudo can ask for a password, then polls for the
-- process to end and re-checks automatically.

local STATE_KEY = "void_state"
local REQUEST_KEY = "void_request"

local CHECK_TIMEOUT_MS = 60000 -- xbps/flatpak checks: each may sync a mirror
local FAST_TIMEOUT_MS = 5000 -- reboot check: local filesystem only
local RUN_POLL_SECONDS = 2
local RUN_GRACE_SECONDS = 12
local AUTO_CHECK_DELAY = 10 -- ticks before an enabled auto-check's first run
local MAX_LISTED = 300 -- packages kept per source for the panel's expandable list

local phase = "idle" -- idle|checking|clean|ready|running|error|missing
local step = "" -- source label being checked (phase == "checking")
local total = 0
local sources = { xbps = { n = 0, items = {} }, flatpak = { n = 0, items = {} } }
local rebootRecommended = false
local dismissed = false
local errMsg = nil
local checkedAt = ""
local stateNonce = 0
local lastRequestNonce = 0

local runTicks = 0
local runSeen = false
local runPollTicks = 0
local updateProcessName = "xbps-install"
local sinceCheck = 0
local startupTicks = 0

local startCheck

local function cfg(key)
    return noctalia.getConfig(key)
end

local function tr(key, args)
    return noctalia.tr(key, args)
end

local function trim(value)
    return noctalia.string.trim(value or "")
end

local function shellQuote(value)
    return "'" .. value:gsub("'", "'\\''") .. "'"
end

-- Package names reach the command line (targeted xbps update, flatpak skip
-- list), so only xbps' own name grammar is accepted. Anything else is dropped
-- with a log line instead of being quoted.
local function ignoreList()
    local raw = cfg("ignore_packages")
    if type(raw) ~= "table" then
        return {}
    end
    local names = {}
    for _, entry in ipairs(raw) do
        local name = trim(tostring(entry))
        if name:match("^[a-zA-Z0-9._+-]+$") ~= nil then
            table.insert(names, name)
        elseif name ~= "" then
            noctalia.log("void-updater: ignoring invalid package name '" .. name .. "'")
        end
    end
    return names
end

local function ignoreSet()
    local set = {}
    for _, name in ipairs(ignoreList()) do
        set[name] = true
    end
    return set
end

-- ── Parsing ──────────────────────────────────────────────────────────────────

-- xbps-install -n prints one action per line:
--   <pkgver> <action> <arch> <repository> <size> <filename-size>
-- e.g.  firefox-125.0.3_1 update x86_64 https://repo.voidlinux.org/current 12 34
-- The pkgver is the version the package updates to. Only "update" actions are
-- pending upgrades; installs for new dependencies are not counted. Lines that
-- do not look like an action (warnings, summaries) are skipped.
local function parseXbpsLines(output, ignored)
    local items = {}
    local n = 0
    for line in (output or ""):gmatch("[^\n]+") do
        local clean = trim(line)
        if clean ~= "" then
            local pkgver, action = clean:match("^(%S+)%s+(%S+)")
            if pkgver ~= nil and action == "update" then
                local name, version = pkgver:match("^(.*)%-(%S+)$")
                if name ~= nil and not ignored[name] then
                    n += 1
                    if #items < MAX_LISTED then
                        table.insert(items, { name = name, from = "", to = version })
                    end
                end
            end
        end
    end
    return n, items
end

-- Flatpak has no "name oldver -> newver" line, so the query joins installed
-- and pending by application id (tab-separated name/from/to).
local function parseTabLines(output, ignored)
    local items = {}
    local n = 0
    for line in (output or ""):gmatch("[^\n]+") do
        local fields = {}
        for field in (line .. "\t"):gmatch("([^\t]*)\t") do
            table.insert(fields, field)
        end
        local name = fields[1] or ""
        if name ~= "" and not ignored[name] then
            n += 1
            if #items < MAX_LISTED then
                table.insert(items, { name = name, from = fields[2] or "", to = fields[3] or "" })
            end
        end
    end
    return n, items
end

-- ── Publishing ───────────────────────────────────────────────────────────────

local function publish()
    stateNonce += 1
    noctalia.state.set(STATE_KEY, {
        nonce = stateNonce,
        phase = phase,
        step = step,
        total = total,
        xbps = sources.xbps,
        flatpak = sources.flatpak,
        rebootRecommended = rebootRecommended,
        dismissed = dismissed,
        err = errMsg,
        checkedAt = checkedAt,
        ignoredCount = #ignoreList(),
        flatpakEnabled = cfg("flatpak_enabled") == true,
    })
end

-- ── Checking pipeline: xbps → Flatpak → reboot → done ───────────────────────

local checkFlatpak
local checkReboot
local finishCheck

local function failCheck(message)
    phase = "error"
    errMsg = message
    publish()
end

checkReboot = function()
    if cfg("check_reboot_needed") ~= true then
        rebootRecommended = false
        finishCheck()
        return
    end
    -- A kernel upgrade replaces the whole /usr/lib/modules/<version> tree.
    -- Once the running kernel's own directory is gone, a reboot is what
    -- switches to the new one. Works for any kernel flavour since it checks
    -- against `uname -r` directly, without naming one.
    local started = noctalia.runAsync(
        [[test -d "/usr/lib/modules/$(uname -r)" && echo present || echo missing]],
        function(result)
            rebootRecommended = trim(result.stdout or "") == "missing"
            finishCheck()
        end,
        FAST_TIMEOUT_MS
    )
    if not started then
        rebootRecommended = false
        finishCheck()
    end
end

checkFlatpak = function(ignored)
    if cfg("flatpak_enabled") ~= true or not noctalia.commandExists("flatpak") then
        sources.flatpak = { n = 0, items = {} }
        checkReboot()
        return
    end
    step = tr("source.flatpak")
    publish()
    -- Flatpak tracks commits, so a version string often doesn't move across
    -- an update. Short commits stand in when it doesn't, joined by
    -- application id in one awk pass.
    -- Each call's own output and exit code are captured before piping into
    -- awk, so a real flatpak failure (e.g. no remote, network down) fails
    -- the whole command instead of awk quietly succeeding on empty input.
    local cmd = [[
listOut=$(flatpak list --columns=application,version,active 2>/dev/null); listCode=$?
updOut=$(flatpak remote-ls --updates --columns=application,version,commit 2>/dev/null); updCode=$?
if [ "$listCode" -ne 0 ] || [ "$updCode" -ne 0 ]; then
  exit 1
fi
{ printf '%s\n' "$listOut" | sed 's/^/L /'
  printf '%s\n' "$updOut" | sed 's/^/R /'
} | awk -F'\t' '
{ tag=substr($1,1,1); app=substr($1,3) }
tag=="L" { v[app]=$2; c[app]=$3 }
tag=="R" { from=v[app]; to=$2
           if (from=="" || to=="" || from==to) { from=substr(c[app],1,7); to=substr($3,1,7) }
           print app"\t"from"\t"to }']]
    local started = noctalia.runAsync(cmd, function(result)
        if result.timedOut then
            sources.flatpak = { n = 0, items = {} }
            checkReboot()
            return
        end
        if result.exitCode ~= 0 then
            noctalia.log("void-updater: flatpak check failed (exit " .. tostring(result.exitCode) .. ")")
            failCheck(tr("err_flatpak_failed"))
            return
        end
        local n, items = parseTabLines(result.stdout, ignored)
        sources.flatpak = { n = n, items = items }
        checkReboot()
    end, CHECK_TIMEOUT_MS)
    if not started then
        sources.flatpak = { n = 0, items = {} }
        checkReboot()
    end
end

-- Default is a rootless in-memory sync: fresh repo data, no writes to
-- /var/db/xbps, so it works from the bar service without sudo. Overridable
-- for setups that prefer an offline local-index check ("xbps-install -un") or
-- a root sync.
local function buildCheckCommand()
    local override = trim(cfg("check_cmd"))
    return override ~= "" and override or "xbps-install -Mun"
end

startCheck = function()
    if phase == "checking" then
        return
    end
    if not noctalia.commandExists("xbps-install") then
        phase = "missing"
        errMsg = tr("err_no_xbps")
        publish()
        return
    end

    phase = "checking"
    errMsg = nil
    sources = { xbps = { n = 0, items = {} }, flatpak = { n = 0, items = {} } }
    rebootRecommended = false
    step = tr("source.xbps")
    publish()

    local ignored = ignoreSet()
    local started = noctalia.runAsync(buildCheckCommand(), function(result)
        if result.timedOut then
            failCheck(tr("err_check_timeout"))
            return
        end
        if result.exitCode ~= 0 then
            noctalia.log("void-updater: xbps check failed (exit " .. tostring(result.exitCode) .. "): " .. trim(result.stderr or ""))
            failCheck(tr("err_check_failed"))
            return
        end
        local n, items = parseXbpsLines(result.stdout, ignored)
        sources.xbps = { n = n, items = items }
        checkFlatpak(ignored)
    end, CHECK_TIMEOUT_MS)

    if not started then
        failCheck(tr("err_spawn"))
    end
end

finishCheck = function()
    total = sources.xbps.n + sources.flatpak.n
    step = ""
    phase = total > 0 and "ready" or "clean"
    dismissed = false
    checkedAt = noctalia.formatTime("%H:%M")
    sinceCheck = 0
    publish()
    if total > 0 and cfg("notify_on_updates") == true then
        noctalia.notify(tr("title"), noctalia.trp("notify_updates", total, { count = total }))
    end
end

-- ── Updating ─────────────────────────────────────────────────────────────────

-- Uses Noctalia's terminal discovery ($TERMINAL, then the usual emulators)
-- unless a terminal is configured.
local function launchTerminal(cmd)
    local term = trim(cfg("terminal"))
    if term == "" then
        return noctalia.runInTerminal(cmd)
    end
    local first = term:match("^%S+") or term
    local bin = first:match("([^/]+)$") or first
    local separator = (bin == "gnome-terminal" or bin == "kgx" or bin == "ptyxis") and "--" or "-e"
    return noctalia.runAsync(term .. " " .. separator .. " sh -lc " .. shellQuote(cmd))
end

-- Builds the update command from the ignore list and Flatpak settings.
-- "update_cmd" overrides it outright, for cases the built default doesn't cover.
local function buildUpdateCommand()
    local override = trim(cfg("update_cmd"))
    if override ~= "" then
        updateProcessName = "xbps-install"
        return override
    end

    local ignored = ignoreList()
    local yesFlag = cfg("assume_yes") == true and "y" or ""
    local flatpakYes = cfg("assume_yes") == true and " -y" or ""
    local parts = {}

    -- xbps. With an empty ignore list this is the plain full upgrade
    -- (`sudo xbps-install -Su`, the standard Void update). xbps-install has
    -- no --ignore, so with ignores the pending list is filtered and the
    -- remaining packages are passed explicitly; the leading -S still syncs
    -- the index first.
    if #ignored > 0 then
        local skipList = shellQuote(table.concat(ignored, "\n"))
        table.insert(
            parts,
            "refs=$(xbps-install -un 2>/dev/null | awk -v ignore="
                .. skipList
                .. [=[ 'BEGIN { n = split(ignore, arr, "\n"); for (i = 1; i <= n; i++) skip[arr[i]] = 1 }
$2 == "update" { name = $1; sub(/-[^-]+$/, "", name); if (!(name in skip)) print name }'); ]=]
                .. [[if [ -n "$refs" ]; then sudo xbps-install -Su]]
                .. yesFlag
                .. [[ $refs; fi]]
        )
    else
        table.insert(parts, "sudo xbps-install -Su" .. yesFlag)
    end
    updateProcessName = "xbps-install"

    if cfg("flatpak_enabled") == true and noctalia.commandExists("flatpak") then
        if #ignored > 0 then
            -- Same ignore list as xbps: filter ignored refs out of the
            -- pending Flatpak list before updating, so an app hidden from the
            -- panel's count can't still slip in through a bare `flatpak update`.
            local skipList = shellQuote(table.concat(ignored, "\n"))
            table.insert(
                parts,
                "flatpak_refs=$(flatpak remote-ls --updates --columns=application 2>/dev/null | awk -v ignore="
                    .. skipList
                    .. [=[ 'BEGIN { n = split(ignore, arr, "\n"); for (i = 1; i <= n; i++) skip[arr[i]] = 1 } !($0 in skip)'); ]=]
                    .. [[if [ -n "$flatpak_refs" ]; then flatpak update]]
                    .. flatpakYes
                    .. [[ $flatpak_refs; fi]]
            )
        else
            table.insert(parts, "flatpak update" .. flatpakYes)
        end
    end

    table.insert(parts, "echo; echo " .. shellQuote(tr("run.press_key")) .. "; read -n 1")
    return table.concat(parts, "; ")
end

local function runUpdate()
    if phase == "running" or phase == "checking" then
        return
    end
    if not noctalia.commandExists("xbps-install") then
        phase = "missing"
        errMsg = tr("err_no_xbps")
        publish()
        return
    end
    if not launchTerminal(buildUpdateCommand()) then
        phase = "error"
        errMsg = tr("err_no_terminal")
        publish()
        noctalia.notifyError(tr("title"), tr("err_no_terminal"))
        return
    end
    phase = "running"
    errMsg = nil
    step = ""
    runTicks = 0
    runPollTicks = 0
    runSeen = false
    publish()
end

-- Polls for the update process. Seeing it then losing it means the run
-- ended, and triggers a re-check. Never seeing it within the grace period
-- re-checks anyway instead of sitting in "running" forever.
local function pollRun()
    runPollTicks += 1
    if runPollTicks < RUN_POLL_SECONDS then
        return
    end
    runPollTicks = 0
    noctalia.processMatches(function(matched)
        if phase ~= "running" then
            return
        end
        if matched then
            runSeen = true
            return
        end
        if runSeen or runTicks >= RUN_GRACE_SECONDS then
            startCheck()
        end
    end, updateProcessName)
end

-- ── Requests, lifecycle ──────────────────────────────────────────────────────

local function handle(action)
    if action == "check" then
        -- Also works as a manual unstick: if the process-poll heuristic in
        -- pollRun() ever misses the update finishing, this forces a re-check
        -- instead of leaving the UI stuck on "running".
        startCheck()
    elseif action == "update" then
        runUpdate()
    elseif action == "dismiss" then
        if not dismissed then
            dismissed = true
            publish()
        end
    end
end

noctalia.state.watch(REQUEST_KEY, function(value)
    if type(value) ~= "table" then
        return
    end
    local nonce = tonumber(value.nonce) or 0
    if nonce <= lastRequestNonce then
        return
    end
    lastRequestNonce = nonce
    handle(value.action)
end)

-- Scriptable control:
--   noctalia msg plugin helmsman/void-updater:service all check
--   noctalia msg plugin helmsman/void-updater:service all update
--   noctalia msg plugin helmsman/void-updater:service all dismiss
function onIpc(event, _payload)
    handle(event)
end

function update()
    if phase == "running" then
        runTicks += 1
        pollRun()
    elseif phase ~= "checking" then
        local hours = tonumber(cfg("auto_check_hours")) or 0
        if hours > 0 then
            if phase == "idle" then
                startupTicks += 1
                if startupTicks >= AUTO_CHECK_DELAY then
                    startCheck()
                end
            else
                sinceCheck += 1
                if sinceCheck >= hours * 3600 then
                    startCheck()
                end
            end
        end
    end
end

noctalia.setUpdateInterval(1000)
if not noctalia.commandExists("xbps-install") then
    phase = "missing"
    errMsg = tr("err_no_xbps")
end
publish()
