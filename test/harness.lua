-- Drives the real main.lua, netbird.sh and netbird binary against a real server.
io.stdout:setvbuf("no")
-- Only KOReader's UI is stubbed. Usage: harness.lua <tun|netstack> <data dir> <key> <peer ip>
local MODE, DATA, SETUP_KEY, PEER_IP = arg[1], arg[2], arg[3], arg[4]

local shown = {}
local scheduled = {}
local UIManager = {
    scheduleIn = function(_, _delay, fn) table.insert(scheduled, fn) end,
    unschedule = function(_, fn)
        for i = #scheduled, 1, -1 do
            if scheduled[i] == fn then table.remove(scheduled, i) end
        end
    end,
    show = function(_, widget) table.insert(shown, widget) end,
    close = function(_, widget) widget.closed = true end,
    forceRePaint = function() end,
    quit = function(_, code) return code end,
}

local function widgetClass()
    local class = {}
    function class:new(o)
        o = setmetatable(o or {}, { __index = class })
        o.class = class
        return o
    end
    return class
end

local settings_store = {}
local LuaSettings = {
    open = function()
        local s = { data = settings_store }
        function s:readSetting(k) return self.data[k] end
        function s:saveSetting(k, v) self.data[k] = v end
        function s:isTrue(k) return self.data[k] == true end
        function s:flipNilOrFalse(k) self.data[k] = not self.data[k] end
        function s:flush() end
        return s
    end,
}

local QRMessage = widgetClass()
local cjson = require("cjson")

package.preload["datastorage"] = function()
    return {
        getFullDataDir = function() return DATA end,
        getSettingsDir = function() return DATA .. "/settings" end,
    }
end
package.preload["device"] = function() return {} end
-- KOReader's own dir. The CA bundle isn't there in this container, so netbird.sh
-- falls back to the other places it looks.
package.preload["libs/libkoreader-lfs"] = function() return { currentdir = function() return "/" end } end
package.preload["dispatcher"] = function() return { registerAction = function() end } end
package.preload["ui/uimanager"] = function() return UIManager end
package.preload["ui/widget/infomessage"] = function() return widgetClass() end
local next_input = ""
local InputDialog = widgetClass()
function InputDialog:onShowKeyboard() end
function InputDialog:getInputText() return next_input end
local ConfirmBox = widgetClass()
local ButtonDialog = widgetClass()
package.preload["ui/widget/inputdialog"] = function() return InputDialog end
package.preload["ui/widget/confirmbox"] = function() return ConfirmBox end
package.preload["ui/widget/buttondialog"] = function() return ButtonDialog end
package.preload["netbird_qr"] = function() return QRMessage end
package.preload["ui/widget/textviewer"] = function() return widgetClass() end
package.preload["ui/network/manager"] = function() return { isConnected = function() return true end } end
package.preload["luasettings"] = function() return LuaSettings end
package.preload["json"] = function() return { decode = cjson.decode } end
package.preload["logger"] = function()
    local noop = function() end
    return { info = noop, warn = noop }
end
package.preload["gettext"] = function() return function(s) return s end end
package.preload["ui/widget/container/widgetcontainer"] = function()
    return { extend = function(_, o) o.__index = o; o.new = function(c) return setmetatable({}, c) end; return o end }
end

local NetBirdPlugin = dofile("/plugin/main.lua")
local Connect = require("netbird_connect")
local http = require("socket.http")
http.TIMEOUT = 10

-- ─── helpers ──────────────────────────────────────────────────────

local failures = 0
local function check(name, ok, detail)
    print((ok and "PASS  " or "FAIL  ") .. name .. ((not ok and detail) and ("  -> " .. tostring(detail)) or ""))
    if not ok then failures = failures + 1 end
end

local function newPlugin()
    local p = NetBirdPlugin:new()
    -- No loader sets p.path here, so main.lua finds itself through debug.getinfo.
    p:init()
    return p
end

local function lastText()
    return shown[#shown] and shown[#shown].text or ""
end

local function sleep(n) os.execute("sleep " .. n) end

--- Run what the plugin scheduled until nothing is left or time runs out, like
-- UIManager's loop would.
local function pump(seconds)
    local deadline = os.time() + seconds
    while #scheduled > 0 and os.time() < deadline do
        local fns = scheduled
        scheduled = {}
        for _, fn in ipairs(fns) do fn() end
        sleep(1)
    end
end

local function fetchPeer()
    return http.request("http://" .. PEER_IP .. ":8080/")
end

local function waitFor(seconds, fn)
    local deadline = os.time() + seconds
    while os.time() < deadline do
        local r = fn()
        if r then return r end
        sleep(2)
    end
    return nil
end

local function fileExists(path)
    local f = io.open(path, "r")
    if f then f:close() return true end
    return false
end

-- ─── scenario ─────────────────────────────────────────────────────

local plugin = newPlugin()
local key_path = plugin:getSetupKeyPath()
os.execute("mkdir -p " .. DATA .. "/settings")
plugin.settings:saveSetting("management_url", "http://netbird-server:80")

local arch = io.popen("uname -m"):read("*l")
print("      cpu: " .. arch)
check("mode is " .. MODE, plugin:desiredMode() == MODE, plugin:desiredMode())
for _, case in ipairs{
    { "100.92.1.5/16", "100.92.255.254" },
    { "100.64.0.1/10", "100.127.255.254" },
    { "10.1.2.3/24", "10.1.2.254" },
    { "", nil },
} do
    check("DNS address for " .. case[1], Connect.dnsAddressFor(case[1]) == case[2], Connect.dnsAddressFor(case[1]))
end
check("not installed", plugin:connectionLabel() == "Not installed", plugin:connectionLabel())

plugin:toggleConnection()
check("tap without binary offers to install", shown[#shown].class == ConfirmBox and lastText():match("isn't installed") ~= nil, lastText())

-- Negative control: this proves a later success really went through NetBird.
check("peer unreachable before connecting", fetchPeer() == nil)

plugin:installNetBird()
check("install succeeds", plugin:isInstalled(), lastText())
check("install verifies and runs the binary", lastText():match("is installed") ~= nil, lastText())
check("off after install", plugin:connectionLabel() == "Off", plugin:connectionLabel())

-- A wrong key must surface an error instead of a five minute silent wait.
local f = assert(io.open(key_path, "w"))
f:write("00000000-0000-0000-0000-000000000000\n")
f:close()
plugin:connect()
pump(60)
check("bad setup key reports an error", lastText():match("could not connect") ~= nil, lastText())
check("bad setup key does not persist connected", not plugin.settings:isTrue("want_connected"))
print("      error shown: " .. lastText():gsub("\n", " "))

-- Good key.
f = assert(io.open(key_path, "w"))
f:write(SETUP_KEY .. "\n")
f:close()
plugin:connect()
pump(90)
check("setup key connects", plugin:getDaemonStatus() == "Connected", plugin:getDaemonStatus())
check("label says connected", plugin:connectionLabel() == "Connected", plugin:connectionLabel())
check("connected state persisted", plugin.settings:isTrue("want_connected"))
check("setup key removed after connecting", not fileExists(key_path))
check("running mode recorded", plugin:runningMode() == MODE, plugin:runningMode())
check("socks hook only in netstack", Connect.socks_enabled == (MODE == "netstack"))
local first_ip = plugin:getStatus().netbirdIp
print("      netbird ip: " .. tostring(first_ip))

local body = waitFor(60, function() return fetchPeer() end)
check("KOReader's HTTP reaches the peer", body and body:match("hello from the peer"), body)
plugin:showStatus()
print("      status: " .. lastText():gsub("\n", " | "))
local started = os.time()
local peer_up = waitFor(90, function()
    local details = plugin:getStatus().peers.details or {}
    for _, d in ipairs(details) do
        if d.netbirdIp == PEER_IP and d.status == "Connected" then return d end
    end
end)
print("      peer marked connected after " .. (os.time() - started) .. "s"
    .. (peer_up and (", type " .. peer_up.connectionType) or ""))
plugin:showStatus()
check("status shows the peer as connected", lastText():match("Peers: [1-9]/") ~= nil, lastText())
check("status shows a bare IP", lastText():match("IP: [%d%.]+\n") ~= nil, lastText())

if MODE == "netstack" then
    -- Must leave the regular network alone.
    local _, code = http.request("http://netbird-server:80/oauth2/.well-known/openid-configuration")
    check("non-NetBird traffic bypasses the proxy", code == 200, code)
    -- A dead peer port must fail, not hang or leak.
    local r, err = http.request("http://" .. PEER_IP .. ":8081/")
    check("closed peer port fails cleanly", r == nil, err)
    local r2 = http.request("http://100.64.255.254:8080/")
    check("unknown peer fails cleanly", r2 == nil)
end

-- The other half of the control: the peer really is the far end of this tunnel.
if MODE == "tun" then
    local route = io.popen("ip route get " .. PEER_IP)
    local via = route:read("*a")
    route:close()
    check("the peer is routed through the tunnel", via:match("dev wt0") ~= nil, via)
end

-- HTTPS is the fragile path: LuaSec takes over the socket after the SOCKS handshake.
local https = require("ssl.https")
https.TIMEOUT = 10
local tls_body = waitFor(30, function()
    return (https.request{ url = "https://" .. PEER_IP .. ":8443/", verify = "none",
        sink = nil, protocol = "any", options = { "all" } })
end)
check("KOReader's HTTPS reaches the peer", tls_body ~= nil, tls_body)

-- A domain resource behind a reverse proxy, reached by name.
local function fetchOpds(scheme)
    if scheme == "https" then
        local parts = {}
        https.request{
            url = "https://opds.internal/", verify = "none", protocol = "any", options = { "all" },
            sink = require("ltn12").sink.table(parts),
        }
        return #parts > 0 and table.concat(parts) or nil
    end
    return (http.request("http://opds.internal/"))
end
local function resolvConf()
    local rf = io.open("/var/run/resolv.conf", "r")
    local content = rf and rf:read("*a")
    if rf then rf:close() end
    return content
end
local resolv_before = resolvConf()

check("a resource name is unreachable before it is listed", fetchOpds("http") == nil)
plugin:saveHostnames("Opds.Internal, other.internal")
pump(90)
check("connected again after listing a hostname", plugin:getDaemonStatus() == "Connected", plugin:getDaemonStatus())
check("WireGuard runs in userspace, as on a Kindle", plugin:getStatus().usesKernelInterface == false,
    plugin:getStatus().usesKernelInterface)
if MODE == "tun" then
    body = waitFor(60, function() return fetchOpds("http") end)
    check("listed name reaches the proxy over HTTP, with its real name", body == "hello from opds", body)
    body = waitFor(30, function() return fetchOpds("https") end)
    check("listed name reaches the proxy over HTTPS, with its real SNI", body == "hello from opds", body)
    local _, code, _, _ = http.request("http://netbird-server:80/oauth2/.well-known/openid-configuration")
    check("unlisted names still use the system's DNS", code == 200, code)
    local none, why = http.request("http://other.internal/")
    check("a listed name NetBird can't resolve fails", none == nil, why)
    print("      reason: " .. tostring(why))
    check("system DNS is unchanged on a read-only /etc", resolvConf() == resolv_before)
else
    check("a listed name fails cleanly in userspace mode", fetchOpds("http") == nil)
end
check("peer still reachable with DNS on", waitFor(60, function() return fetchPeer() end) ~= nil)

-- Plugin instantiated again (FileManager -> ReaderUI) while the daemon runs.
UIManager._netbird_autostart_done = nil
plugin = newPlugin()
check("a second instance leaves the daemon alone", #scheduled == 0)
check("a second instance keeps the hook state", Connect.socks_enabled == (MODE == "netstack"))

-- Cold boot: daemon gone without `netbird down`, KOReader starts fresh.
os.execute("kill -9 $(cat /tmp/netbird-koreader/daemon.pid); sleep 1")
UIManager._netbird_autostart_done = nil
plugin = newPlugin()
check("autostart scheduled when left connected", #scheduled == 1)
pump(5)
local state = waitFor(90, function() return plugin:getDaemonStatus() == "Connected" and "Connected" end)
check("autostart reconnects after a hard kill", state == "Connected", plugin:getDaemonStatus())
check("same identity after reboot", plugin:getStatus().netbirdIp == first_ip, plugin:getStatus().netbirdIp)
body = waitFor(60, function() return fetchPeer() end)
check("peer reachable after reboot", body and body:match("hello from the peer"), body)
if MODE == "tun" then
    body = waitFor(60, function() return fetchOpds("http") end)
    check("listed name reachable after reboot", body == "hello from opds", body)
end

-- USB storage mode.
local exit = UIManager.quit(UIManager, 86)
check("USB storage mode stops the daemon", not plugin:isRunning())
check("USB storage mode still quits", exit == 86, exit)
UIManager._netbird_autostart_done = nil
plugin = newPlugin()
pump(5)
state = waitFor(90, function() return plugin:getDaemonStatus() == "Connected" and "Connected" end)
check("back after USB storage mode", state == "Connected", plugin:getDaemonStatus())

-- Disconnect sticks across a restart, and reconnecting needs no key.
plugin:toggleConnection()
check("disconnect stops the daemon", not plugin:isRunning())
check("label says off", plugin:connectionLabel() == "Off", plugin:connectionLabel())
check("disconnect persists", not plugin.settings:isTrue("want_connected"))
check("socks hook off after disconnect", Connect.socks_enabled == false)
UIManager._netbird_autostart_done = nil
plugin = newPlugin()
check("off stays off on the next launch", #scheduled == 0 and not plugin:isRunning())

plugin:toggleConnection()
pump(90)
check("reconnects without a setup key", plugin:getDaemonStatus() == "Connected", plugin:getDaemonStatus())
check("still the same identity", plugin:getStatus().netbirdIp == first_ip, plugin:getStatus().netbirdIp)
body = waitFor(60, function() return fetchPeer() end)
check("peer reachable after reconnect", body and body:match("hello from the peer"), body)

-- A changed management server must really be used on the next connect, not just
-- saved. An unreachable one is the easy way to see which server it talks to.
plugin:saveManagementUrl("http://netbird-server:81")
check("changing the server disconnects", not plugin:isRunning())
check("changing the server forgets the identity", not fileExists(DATA .. "/netbird/state/config.json"))
plugin:connect()
pump(40)
check("a changed management server takes effect", plugin:getStatus().management.url:match(":81$") ~= nil,
    plugin:getStatus().management.url)
plugin:saveManagementUrl("http://netbird-server:80")
f = assert(io.open(key_path, "w"))
f:write(SETUP_KEY .. "\n")
f:close()
plugin:connect()
pump(90)
check("back on the original management server", plugin:getDaemonStatus() == "Connected", plugin:getDaemonStatus())
body = waitFor(60, function() return fetchPeer() end)
check("peer reachable on the new identity", body and body:match("hello from the peer"), body)

-- Off means off: the name goes back to the regular network.
if MODE == "tun" then
    plugin:toggleConnection()
    check("the hook lets go of names once disconnected", next(Connect.hostnames) == nil)
    check("system DNS is intact after disconnecting", resolvConf() == resolv_before)
    plugin:toggleConnection()
    pump(90)
end

-- Update path: the same pinned version is a no-op that keeps the connection.
plugin:installNetBird()
pump(90)
check("re-running install keeps NetBird connected", plugin:getDaemonStatus() == "Connected", plugin:getDaemonStatus())

plugin:uninstallNetBird()
check("uninstall stops the daemon", not plugin:isRunning())
check("uninstall removes everything", not fileExists(DATA .. "/netbird/netbird") and not fileExists(DATA .. "/netbird/state/config.json"))
check("uninstall resets the label", plugin:connectionLabel() == "Not installed", plugin:connectionLabel())

-- SSO: no key and no identity, so `up` must hand us a URL for the phone. reader.sh
-- sets DISPLAY as a Kindle does, which must not push NetBird to a localhost redirect.
local function waitForQR(previous)
    local deadline = os.time() + 30
    while os.time() < deadline do
        local fns = scheduled
        scheduled = {}
        for _, fn in ipairs(fns) do fn() end
        for i = #shown, 1, -1 do
            local w = shown[i]
            if w.class == QRMessage and w.url ~= previous then return w.url, w.code end
        end
        sleep(2)
    end
    os.execute("cat /tmp/netbird-koreader/up.log")
    return nil
end

plugin:installNetBird()
plugin.settings:saveSetting("management_url", "http://netbird-server:80")
local before_qr = #shown
plugin:toggleConnection()
local qr_url, qr_code = waitForQR()
check("no key leads to a sign-in QR code", qr_url ~= nil)
print("      qr url: " .. tostring(qr_url))
check("QR code is the device flow a phone can finish",
    qr_url and qr_url:match("/device") and not qr_url:match("localhost"), qr_url)
check("the QR screen shows the code to compare", qr_code ~= nil and qr_url:find(qr_code, 1, true) ~= nil, qr_code)
local told_to_wait, code_behind_qr
for i = before_qr + 1, #shown do
    local text = tostring(shown[i].text)
    if text:match("Connecting to NetBird") then told_to_wait = shown[i] end
    if qr_code and text:find(qr_code, 1, true) and not shown[i].closed then code_behind_qr = true end
end
check("a wait message appears right after the tap", told_to_wait ~= nil)
check("the wait message gives way to the QR code", told_to_wait and told_to_wait.closed == true)
check("the wait message has no timeout that would close it", told_to_wait and told_to_wait.timeout == nil)
check("the code stays on screen behind the QR", code_behind_qr == true)
check("sign-in label asks for a tap", plugin:connectionLabel():match("sign in") ~= nil, plugin:connectionLabel())

-- Abandon the QR code and use a setup key instead. The pause lets the daemon
-- record the cancelled sign-in, as it does on a slow device.
f = assert(io.open(key_path, "w"))
f:write(SETUP_KEY .. "\n")
f:close()
sleep(3)
local before = #shown
plugin:connect()
pump(90)
check("setup key works after an abandoned QR code", plugin:getDaemonStatus() == "Connected", plugin:getDaemonStatus())
local complaint
for i = before + 1, #shown do
    if tostring(shown[i].text):match("could not connect") then complaint = shown[i].text end
end
check("the abandoned sign-in is not reported as a failure", complaint == nil, complaint)
local still_open
for _, w in ipairs(shown) do
    if w.text and tostring(w.text):match("Connecting to NetBird") and not w.closed then still_open = w.text end
end
check("no wait message left behind once connected", still_open == nil, still_open)
check("setup key removed after an abandoned QR code", not fileExists(key_path))
plugin:disconnect()

-- A bad key must not linger and hijack the next sign-in.
os.execute("rm -rf " .. DATA .. "/netbird/state")
f = assert(io.open(key_path, "w"))
f:write("00000000-0000-0000-0000-000000000000\n")
f:close()
plugin:connect()
pump(60)
check("a refused key is removed", not fileExists(key_path))
plugin:showStatus()
check("status explains the failure", lastText():match("Last error") ~= nil, lastText())

-- Sign in for real: a second try after a failure, finished the way a phone would.
plugin:startQRLogin()
qr_url = waitForQR(qr_url)
check("QR code offered after a failed key", qr_url ~= nil)
local approved = os.execute("sh /test/approve.sh '" .. tostring(qr_url) .. "' admin@example.com 'Test-Passw0rd-123!'")
check("the sign-in page accepts the device", approved == 0 or approved == true, approved)
pump(90)
check("QR sign-in connects", plugin:getDaemonStatus() == "Connected", plugin:getDaemonStatus())
check("connected state persisted after QR", plugin.settings:isTrue("want_connected"))
body = waitFor(60, function() return fetchPeer() end)
check("peer reachable after QR sign-in", body and body:match("hello from the peer"), body)
plugin:disconnect()
check("disconnect stops cleanly", not plugin:isRunning())
check("polling stopped", #scheduled == 0)

-- The whole setup, from nothing, the way a new user goes through it.
local function top(class, what)
    local w = shown[#shown]
    check("setup shows " .. what, w and w.class == class, w and w.text)
    return w
end
plugin:uninstallNetBird()
plugin.settings:saveSetting("hostnames", nil)
plugin.settings:saveSetting("management_url", "http://netbird-server:80")

plugin:setupStart()
top(ConfirmBox, "an offer to install").ok_callback()
check("setup installs after asking", plugin:isInstalled())
local explain = top(ConfirmBox, "this device's mode")
if MODE == "tun" then
    check("TUN setup explains domain resources", explain.text:match("TUN mode") and explain.text:match("domain resource"), explain.text)
else
    check("userspace setup explains IP only", explain.text:match("userspace mode") and explain.text:match("NetBird IP") and not explain.text:match("domain resource"), explain.text)
end
explain.ok_callback()
if MODE == "tun" then
    next_input = "opds.internal"
    top(InputDialog, "a request for the domain name").buttons[1][2].callback()
end
local signin = top(ButtonDialog, "the sign-in choices")
check("setup offers QR, key and server", #signin.buttons == 3)
next_input = SETUP_KEY
signin.buttons[2][1].callback()
top(InputDialog, "a request for the setup key").buttons[1][2].callback()
pump(90)
check("setup ends connected", plugin:getDaemonStatus() == "Connected", plugin:getDaemonStatus())
check("setup persists connected", plugin.settings:isTrue("want_connected"))
local done = lastText()
print("      final: " .. done:gsub("\n", " "))
check("setup says what to enter in KOReader", done:match(MODE == "tun" and "https://opds%.internal" or "NetBird IP") ~= nil, done)
if MODE == "tun" then
    body = waitFor(60, function() return fetchOpds("http") end)
    check("the resource from setup is reachable", body == "hello from opds", body)
    -- Running it again when already set up must not disturb anything.
    plugin:setupStart()
    shown[#shown].ok_callback()
    next_input = "opds.internal"
    top(InputDialog, "the current name").buttons[1][2].callback()
    check("setup on a connected device just finishes", lastText():match("is connected") ~= nil, lastText())
    -- Adding a name to a connected device reconnects, then finishes.
    plugin:setupStart()
    shown[#shown].ok_callback()
    next_input = "opds.internal, other.internal"
    top(InputDialog, "the current name again").buttons[1][2].callback()
    pump(90)
    check("changing the name through setup reconnects", plugin:getDaemonStatus() == "Connected", plugin:getDaemonStatus())
    check("changing the name through setup finishes", lastText():match("is connected") ~= nil, lastText())
end
plugin:disconnect()

print(failures == 0 and "ALL PASSED (" .. MODE .. ")" or (failures .. " FAILED (" .. MODE .. ")"))
os.exit(failures == 0 and 0 or 1)
