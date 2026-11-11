--- Drives the real NetBird plugin inside the KOReader emulator, the way a user
-- would: through its menu, dialogs and buttons. Only the netbird binary is a
-- stand-in. Results go to $NETBIRD_EMU_OUT/results.txt, screenshots next to it.
local OUT = os.getenv("NETBIRD_EMU_OUT")
if not OUT then return { disabled = true } end

local Device = require("device")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")

local Driver = WidgetContainer:extend{ name = "netbirdtest", is_doc_only = false }

local FAKE = os.getenv("NETBIRD_EMU_FAKE")
-- "first" ends in a restart, "restart" checks what comes back and then quits.
local PHASE = os.getenv("NETBIRD_EMU_PHASE") or "first"
local BOOK = os.getenv("NETBIRD_EMU_BOOK")
local RUN_DIR = "/tmp/netbird-koreader"

local results = assert(io.open(OUT .. "/results-" .. PHASE .. ".txt", "w"))
local failures = 0

local function report(line)
    results:write(line, "\n")
    results:flush()
    logger.info("NetBirdTest:", line)
end

local function check(name, ok, detail)
    if not ok then failures = failures + 1 end
    report((ok and "PASS  " or "FAIL  ") .. name
        .. ((not ok and detail ~= nil) and ("  -> " .. tostring(detail)) or ""))
end

local function readFile(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

local function exists(path) return readFile(path) ~= nil end

-- ─── the script runs as a coroutine, so it can wait for the UI ─────

local script

local function sleep(seconds)
    UIManager:scheduleIn(seconds, function() assert(coroutine.resume(script)) end)
    coroutine.yield()
end

local function waitFor(seconds, fn)
    local deadline = os.time() + seconds
    while true do
        local value = fn()
        if value or os.time() >= deadline then return value end
        sleep(0.25)
    end
end

-- ─── UI helpers ───────────────────────────────────────────────────

local function ui()
    return require("apps/reader/readerui").instance or require("apps/filemanager/filemanager").instance
end

local function plugin() return ui().netbird end

local function top()
    local stack = UIManager._window_stack
    return stack[#stack] and stack[#stack].widget
end

--- The text a dialog shows, whatever kind it is.
local function textOf(widget)
    if not widget then return "" end
    return tostring(widget.text or widget.title or "")
end

local function topText() return textOf(top()) end

local shots = 0
local function shoot(name)
    UIManager:forceRePaint()
    shots = shots + 1
    local path = string.format("%s/%02d-%s.png", OUT, shots, name)
    Device.screen:shot(path)
    check("screenshot " .. name, exists(path), path)
end

--- Find a button by its label anywhere in a widget tree, as a tap would.
local function findButton(widget, label, seen)
    seen = seen or {}
    if type(widget) ~= "table" or seen[widget] then return nil end
    seen[widget] = true
    if widget.text == label and type(widget.callback) == "function" and widget.onTapSelectButton then
        return widget
    end
    for k, v in pairs(widget) do
        if type(v) == "table" and k ~= "show_parent" and k ~= "parent" and k ~= "ui" and k ~= "dialog" then
            local found = findButton(v, label, seen)
            if found then return found end
        end
    end
end

local function tap(label)
    local widget = top()
    local button = findButton(widget, label)
    check("tap \"" .. label .. "\" on " .. textOf(widget):sub(1, 40):gsub("\n", " "), button ~= nil)
    if button then button.callback() end
    sleep(0.5)
end

--- Close whatever messages are on top, as tapping them would.
local function dismissAll()
    for _ = 1, 10 do
        local widget = top()
        if not widget or widget == ui() or widget.covers_fullscreen then break end
        UIManager:close(widget)
    end
    sleep(0.3)
end

local function waitForTop(seconds, pattern)
    return waitFor(seconds, function() return topText():find(pattern) ~= nil end)
end

local function approveOnPhone()
    local f = assert(io.open(plugin().home_dir .. "/state/approved", "w"))
    f:close()
end

local function install()
    os.execute("mkdir -p '" .. plugin().home_dir .. "' && cp '" .. FAKE .. "' '" .. plugin():getBinaryPath() .. "'")
end

--- Open the NetBird menu in the file manager, the way a user does.
local function openMenu()
    local menu = ui().menu
    menu:onShowMenu()
    local touchmenu = menu.menu_container[1]
    for tab_index, tab in ipairs(touchmenu.tab_item_table) do
        for _, item in ipairs(tab) do
            if item.text == "Network" and item.sub_item_table then
                for _, sub in ipairs(item.sub_item_table) do
                    if sub.text == "NetBird VPN" then
                        touchmenu:switchMenuTab(tab_index)
                        touchmenu:onMenuSelect(item)
                        touchmenu:onMenuSelect(sub)
                        sleep(0.5)
                        return touchmenu, sub
                    end
                end
            end
        end
    end
    check("NetBird VPN is in Network", false)
end

local function closeMenu()
    ui().menu:onCloseFileManagerMenu()
    sleep(0.3)
end

-- ─── scenario ─────────────────────────────────────────────────────

local function run()
    sleep(2)
    local nb = plugin()
    check("plugin loaded", nb ~= nil)
    check("plugin dir found from a separate data dir", exists(nb.plugin_dir .. "/netbird.sh"), nb.plugin_dir)
    check("emulator chooses userspace mode without CAP_NET_ADMIN", nb:desiredMode() == "netstack", nb:desiredMode())

    -- The menu, before anything is installed.
    local touchmenu, item = openMenu()
    check("top row says not installed", touchmenu and item.sub_item_table[1].text_func() == "Not installed")
    shoot("menu-not-installed")
    closeMenu()

    -- The real install refuses this CPU, and says so.
    nb:installNetBird()
    sleep(1)
    check("install refuses x86 with a message", topText():find("Unsupported CPU", 1, true), topText())
    shoot("install-unsupported")
    dismissAll()

    install()
    check("installed", nb:isInstalled())

    -- Setup, start to finish, with a QR code.
    nb:setupStart()
    sleep(0.5)
    check("setup explains userspace mode", topText():find("userspace mode", 1, true), topText())
    shoot("setup-mode")
    tap("Continue")
    check("sign-in choices shown", topText() == "Sign in to NetBird", topText())
    shoot("setup-sign-in")
    tap("Scan QR code")
    local qr = waitFor(30, function() return nb._sign_in_qr end)
    check("QR code shown", qr ~= nil)
    check("QR code carries the URL", qr and qr.url:find("user_code=WXYZ-2345", 1, true), qr and qr.url)
    check("QR code shows the code to compare", qr and qr.code == "WXYZ-2345", qr and qr.code)
    shoot("sign-in-qr")
    approveOnPhone()
    check("setup ends by saying what to type", waitForTop(20, "Add your OPDS catalog"), topText())
    shoot("setup-finished")
    check("remembers to stay connected", nb.settings:isTrue("want_connected"))
    check("connected in userspace mode", nb:runningMode() == "netstack", nb:runningMode())
    dismissAll()

    touchmenu = openMenu()
    nb:invalidateState()
    check("top row says connected", touchmenu.item_table[1].text_func() == "Connected",
        touchmenu.item_table[1].text_func())
    shoot("menu-connected")
    closeMenu()

    nb:showStatus()
    sleep(0.5)
    check("status shows the IP", topText():find("IP: 100.92.1.5", 1, true), topText())
    shoot("status")
    dismissAll()

    -- A cancelled setup must not take over a later, unrelated connect.
    nb:toggleConnection()
    sleep(1)
    check("disconnected", not nb:isRunning())
    dismissAll()
    nb:setupSignIn()
    sleep(0.5)
    tap("Use a setup key")
    check("asks for a key", topText() == "Setup key", topText())
    shoot("setup-key")
    tap("Cancel")
    check("cancelled setup leaves nothing pending", nb._after_connect == nil)
    nb:toggleConnection()
    check("plain reconnect says connected, not setup",
        waitForTop(20, "^NetBird connected%.$"), topText())
    dismissAll()

    -- Uninstall asks first.
    openMenu()
    closeMenu()
    nb:confirmUninstall()
    sleep(0.5)
    check("uninstall asks first", topText():find("Uninstall NetBird?", 1, true), topText())
    shoot("uninstall-confirm")
    tap("Cancel")
    check("cancel keeps NetBird and its identity",
        nb:isInstalled() and nb:isRunning() and exists(nb.home_dir .. "/state/config.json"))
    nb:confirmUninstall()
    sleep(0.5)
    tap("Uninstall")
    sleep(1)
    check("uninstall removes NetBird and its identity",
        not nb:isInstalled() and not nb:isRunning() and not exists(nb.home_dir .. "/state/config.json"))
    dismissAll()

    -- A sign-in survives switching from the file browser to a book.
    install()
    nb:connect()
    check("QR code shown again", waitFor(30, function() return nb._sign_in_qr end) ~= nil)
    local old = nb
    require("apps/reader/readerui"):showReader(BOOK)
    check("book opened", waitFor(30, function()
        return require("apps/reader/readerui").instance and plugin() ~= old
    end))
    sleep(1)
    nb = plugin()
    check("old instance stopped polling", old._poll_fn == nil)
    check("new instance carries on with the sign-in", nb._poll_fn ~= nil)
    check("QR code shown over the book", waitFor(10, function() return nb._sign_in_qr end) ~= nil)
    shoot("sign-in-resumed-in-reader")
    approveOnPhone()
    check("sign-in finished from the book", waitForTop(20, "NetBird connected"), topText())
    dismissAll()

    -- A TUN device that looks usable but isn't: fall back instead of failing.
    nb:toggleConnection()
    sleep(1)
    dismissAll()
    local Plugin = getmetatable(nb).__index
    local orig_tun = Plugin.hasTunDevice
    Plugin.hasTunDevice = function() return true end
    check("pretending TUN works", nb:desiredMode() == "tun")
    nb:connect()
    check("connects after TUN fails", waitForTop(40, "NetBird connected"), topText())
    check("fell back to userspace mode", nb:runningMode() == "netstack", nb:runningMode())
    check("and stays there", nb:desiredMode() == "netstack")
    Plugin.hasTunDevice = orig_tun
    shoot("tun-fallback")
    dismissAll()

    -- A restart keeps the daemon for the next KOReader to adopt. run.sh checks.
    local pid = readFile(RUN_DIR .. "/daemon.pid")
    local f = assert(io.open(OUT .. "/daemon.pid", "w"))
    f:write(pid or "")
    f:close()
    check("daemon running before restart", nb:isRunning())
    report(failures == 0 and "ALL PASSED (first run)" or (failures .. " FAILED (first run)"))
    results:close()
    UIManager:restartKOReader()
end

--- After a restart: the daemon from before is adopted, then leaving stops it.
local function afterRestart()
    sleep(2)
    local nb = plugin()
    check("the daemon from before the restart is still running", nb:isRunning())
    check("and is adopted, not started again",
        (readFile(RUN_DIR .. "/daemon.pid") or "") == (readFile(OUT .. "/daemon.pid") or "-"))
    check("its mode is followed", require("netbird_connect").socks_enabled == true)
    nb:invalidateState()
    check("top row says connected", nb:connectionLabel() == "Connected", nb:connectionLabel())
    report(failures == 0 and "ALL PASSED (after restart)" or (failures .. " FAILED (after restart)"))
    results:close()
    UIManager:quit()
end

function Driver:init()
    if UIManager._netbird_test_started then return end
    UIManager._netbird_test_started = true
    script = coroutine.create(function()
        local ok, err = xpcall(PHASE == "restart" and afterRestart or run, debug.traceback)
        if not ok then
            check("scenario ran to the end", false, err)
            report(failures .. " FAILED (in emulator)")
            results:close()
            UIManager:quit()
        end
    end)
    UIManager:scheduleIn(1, function() assert(coroutine.resume(script)) end)
end

return Driver
