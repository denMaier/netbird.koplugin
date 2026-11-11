local DataStorage = require("datastorage")
local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local LuaSettings = require("luasettings")
local lfs = require("libs/libkoreader-lfs")
local NetBirdConnect = require("netbird_connect")
-- The plugin's dir is only on package.path while it loads, so this can't wait. A
-- build without the QR widgets still works: it shows the URL as text instead.
local has_qr, NetBirdQR = pcall(require, "netbird_qr")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local json = require("json")
local logger = require("logger")
local _ = require("gettext")

local NetBirdPlugin = WidgetContainer:extend{
    name = "netbird",
    is_doc_only = false,
}

local DEFAULT_MANAGEMENT_URL = "https://api.netbird.io:443"

-- Sockets and sign-in output go to tmpfs. The data dir is often FAT, which has
-- no unix sockets.
local RUN_DIR = "/tmp/netbird-koreader"

-- `netbird up` blocks for as long as an SSO sign-in takes, so it runs in the
-- background and we poll instead.
local LOGIN_POLL_INTERVAL = 2
local LOGIN_POLL_TIMEOUT = 300

-- The menu asks for the connection state on every redraw, and each ask costs a
-- subprocess on a slow CPU. Cache briefly; any action invalidates it.
local STATE_CACHE_TTL = 2

-- KOReader's exit code for a restart in place (KO_RC_RESTART). Every other way out
-- leaves KOReader, and the daemon must not outlive it.
local KO_RC_RESTART = 85

-- How long autoStart keeps checking for the daemon it started in the background.
local AUTOSTART_WATCH_TIMEOUT = 30

-- linux/capability.h
local CAP_NET_ADMIN = 12

local function shellQuote(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

--- KOReader's LuaJIT returns the raw wait status from os.execute, Lua 5.2+ returns
-- true, "exit", code. Accept both, so a test under plain Lua behaves like a device.
local function execSucceeded(ok, code)
    if ok == true then
        return code == 0
    end
    return ok == 0
end

-- ─── setup ────────────────────────────────────────────────────────

function NetBirdPlugin:init()
    -- The loader sets self.path, relative to KOReader's own dir when the plugin is
    -- a built-in one. Plugins can also live in the data dir, which isn't always
    -- the same place, so don't assume either.
    self.koreader_dir = lfs.currentdir()
    self.plugin_dir = self.path
        or debug.getinfo(1, "S").source:gsub("^@", ""):gsub("/main%.lua$", "")
    if self.plugin_dir:sub(1, 1) ~= "/" then
        self.plugin_dir = self.koreader_dir .. "/" .. self.plugin_dir
    end
    -- Outside the plugin dir, so updating the plugin keeps the device's identity.
    self.home_dir = DataStorage:getFullDataDir() .. "/netbird"

    self.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/netbird.lua")

    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end
    Dispatcher:registerAction("toggle_netbird_vpn",
        { category = "none", event = "ToggleNetBird", title = _("Toggle NetBird VPN"), general = true })

    self:installQuitHook()
    self:autoStart()
    self:resumeSignIn()
end

--- Stop NetBird whenever KOReader exits, except to restart in place. The daemon
-- runs from the data partition, so left running it would keep that busy: for USB
-- storage mode (86), or for the stock reader's own USB mode after exiting (0, 87),
-- and it would keep its memory for no one. want_connected is untouched, so the
-- next start brings it back. A restart (85) keeps it, and autoStart adopts it.
-- UIManager is a singleton and the plugin is instantiated for both ReaderUI and
-- FileManager, so wrap it only once.
function NetBirdPlugin:installQuitHook()
    if UIManager._netbird_quit_hook then
        return
    end
    UIManager._netbird_quit_hook = true

    local stop_command = self:scriptCommand("stop")
    local orig_quit = UIManager.quit
    UIManager.quit = function(uimgr, exit_code, ...)
        -- KOReader calls quit again on the way out without a code, which keeps the
        -- one set before, as quit itself does.
        local code = exit_code or uimgr._exit_code or 0
        if code ~= KO_RC_RESTART and not UIManager._netbird_stopped_on_quit
                and NetBirdPlugin.isRunning() then
            UIManager._netbird_stopped_on_quit = true
            logger.info("NetBird: stopping the daemon, KOReader exits with", code)
            os.execute(stop_command) -- synchronous, it must be gone before an unmount
        end
        return orig_quit(uimgr, exit_code, ...)
    end
end

--- Bring the daemon back on launch if the user left NetBird connected. The daemon
-- reconnects by itself from its saved config. Off stays off, and no daemon runs.
-- Not on suspend: the kernel freezes the daemon and it recovers on resume.
function NetBirdPlugin:autoStart()
    if self:isRunning() then
        self:applyConnectMode(self:runningMode())
        return
    end
    if UIManager._netbird_autostart_done or not self.settings:isTrue("want_connected")
            or not self:isInstalled() then
        return
    end
    UIManager._netbird_autostart_done = true
    self:applyConnectMode(self:desiredMode())
    -- In the background, so that startup does not wait for the daemon's socket.
    -- Once it is up, follow the mode it really runs in.
    UIManager:scheduleIn(3, function()
        os.execute(self:scriptCommand("start") .. " >/dev/null 2>&1 &")
        local deadline = os.time() + AUTOSTART_WATCH_TIMEOUT
        local function watch()
            if self:isRunning() and self:runningMode() then
                self:applyConnectMode(self:runningMode())
            elseif os.time() < deadline then
                UIManager:scheduleIn(2, watch)
            end
        end
        UIManager:scheduleIn(2, watch)
    end)
end

--- The plugin is created anew when KOReader switches between the file browser and
-- a book. A sign-in still waiting for the phone carries on in the new one.
function NetBirdPlugin:resumeSignIn()
    if self:isRunning() and self:isSigningIn() then
        logger.info("NetBird: resuming the sign-in in progress")
        self:applyConnectMode(self:runningMode())
        self:startLoginPolling()
    end
end

--- The old instance's timers and screens go with it, so they don't act twice.
function NetBirdPlugin:onCloseWidget()
    self:stopLoginPolling()
    self:closeSignInQR()
end

-- ─── paths and shell ──────────────────────────────────────────────

function NetBirdPlugin:getBinaryPath() return self.home_dir .. "/netbird" end
function NetBirdPlugin:getSetupKeyPath() return self.home_dir .. "/setup.key" end
function NetBirdPlugin:getLogPath() return self.home_dir .. "/netbird.log" end

function NetBirdPlugin:getManagementUrl()
    return self.settings:readSetting("management_url") or DEFAULT_MANAGEMENT_URL
end

function NetBirdPlugin:scriptCommand(command)
    local mode = command == "start" and (" NB_MODE=" .. shellQuote(self:desiredMode())) or ""
    -- DNS stays off unless a hostname needs it: with it on, NetBird rewrites
    -- resolv.conf wherever that is writable, and nobody else should carry that.
    local dns = next(self:getHostnames()) and " NB_USE_DNS=1" or ""
    return "NB_HOME=" .. shellQuote(self.home_dir)
        .. " NB_RUN=" .. shellQuote(RUN_DIR)
        -- KOReader's own dir, which holds the CA bundle
        .. " NB_KOREADER_DIR=" .. shellQuote(self.koreader_dir)
        .. " NB_MANAGEMENT_URL=" .. shellQuote(self:getManagementUrl())
        .. dns
        .. mode
        .. " sh " .. shellQuote(self.plugin_dir .. "/netbird.sh") .. " " .. command
end

function NetBirdPlugin:runScript(command)
    local ok, _exit, code = os.execute(self:scriptCommand(command))
    return execSucceeded(ok, code)
end

function NetBirdPlugin:readScript(command)
    local h = io.popen(self:scriptCommand(command) .. " 2>&1")
    if not h then return "" end
    local output = h:read("*a") or ""
    h:close()
    return output
end

local function readFile(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    return content
end

-- ─── checks ───────────────────────────────────────────────────────

function NetBirdPlugin:isInstalled()
    local f = io.open(self:getBinaryPath(), "r")
    if not f then return false end
    f:close()
    return true
end

--- Whether the process in a pid file is still ours: a pid can be reused. Same check
-- as alive in netbird.sh, without paying for a subprocess.
local function pidFileAlive(name)
    local pid = readFile(RUN_DIR .. "/" .. name)
    pid = pid and pid:match("%d+")
    if not pid then return false end
    local comm = readFile("/proc/" .. pid .. "/comm")
    return comm ~= nil and comm:match("^netbird%s*$") ~= nil
end

-- Also called without an instance, from the quit hook.
function NetBirdPlugin.isRunning()
    return pidFileAlive("daemon.pid")
end

--- A `netbird up` still waiting for the user to approve this device.
function NetBirdPlugin:isSigningIn()
    return pidFileAlive("up.pid")
end

--- A TUN device needs the driver, which a device node alone doesn't prove, and
-- CAP_NET_ADMIN to create the interface. Opening the node asks the driver, and
-- creates nothing until an ioctl that we never send.
function NetBirdPlugin:hasTunDevice()
    local f = io.open("/dev/net/tun", "r+")
    if not f then return false end
    f:close()
    local status = readFile("/proc/self/status") or ""
    local caps = status:match("CapEff:%s*(%x+)")
    if not caps then return false end
    local low = tonumber(caps:sub(-4), 16)
    return math.floor(low / 2 ^ CAP_NET_ADMIN) % 2 == 1
end

--- Prefer a real TUN device: everything on the device can then reach peers.
-- Netstack works anywhere, but only KOReader's own connections get through, by way
-- of netbird_connect.lua. A TUN interface that failed once falls back to netstack
-- until KOReader restarts.
function NetBirdPlugin:desiredMode()
    if self.settings:isTrue("force_userspace") or NetBirdPlugin._tun_failed
            or not self:hasTunDevice() then
        return "netstack"
    end
    return "tun"
end

--- The mode the running daemon was started in, which may not be the desired one.
function NetBirdPlugin:runningMode()
    return readFile(RUN_DIR .. "/mode")
end

--- Which of KOReader's connections need help, for a daemon in this mode. nil is no
-- daemon, where nothing does: a listed name then goes to the regular DNS as usual.
function NetBirdPlugin:applyConnectMode(mode)
    NetBirdConnect.socks_enabled = mode == "netstack"
    NetBirdConnect.hostnames = mode == "tun" and self:getHostnames() or {}
    NetBirdConnect.dns_host = nil
    NetBirdConnect.is_running = NetBirdPlugin.isRunning
    NetBirdConnect.find_dns_host = function()
        local status = self:getStatus()
        return status and NetBirdConnect.dnsAddressFor(status.netbirdIp)
    end
end

--- The set of names to resolve through NetBird, from a list separated by commas
-- or spaces.
function NetBirdPlugin:getHostnames()
    local names = {}
    for name in (self.settings:readSetting("hostnames") or ""):gmatch("[^%s,]+") do
        names[name:lower()] = true
    end
    return names
end

function NetBirdPlugin:hasNetwork()
    local ok, NetworkMgr = pcall(require, "ui/network/manager")
    return not ok or NetworkMgr:isConnected()
end

-- ─── state ────────────────────────────────────────────────────────

function NetBirdPlugin:getStatus()
    local raw = self:readScript("status")
    local ok, status = pcall(json.decode, raw)
    if ok and type(status) == "table" then
        return status
    end
    return nil
end

function NetBirdPlugin:getDaemonStatus()
    local status = self:getStatus()
    return status and status.daemonStatus
end

function NetBirdPlugin:getCachedDaemonStatus()
    local now = os.time()
    local cached = self._state_cache
    if cached and (now - cached.at) < STATE_CACHE_TTL then
        return cached.state
    end
    local state = self:getDaemonStatus()
    self._state_cache = { at = now, state = state }
    return state
end

function NetBirdPlugin:invalidateState()
    self._state_cache = nil
end

local function needsSignIn(state)
    return state == "NeedsLogin" or state == "LoginFailed" or state == "SessionExpired"
end

--- What the top row says. It reports the connection, not the process: a daemon
-- that is up but signed out is not connected.
function NetBirdPlugin:connectionLabel()
    if not self:isInstalled() then
        return _("Not installed")
    end
    if not self:isRunning() then
        return _("Off")
    end
    local state = self:getCachedDaemonStatus()
    if state == "Connected" then
        return _("Connected")
    end
    if needsSignIn(state) then
        return _("Not connected") .. " — " .. _("tap to sign in")
    end
    return _("Connecting…")
end

--- One control for connect, disconnect and sign-in. The label says which of the
-- three a tap will do. A daemon stuck connecting can always be turned off.
function NetBirdPlugin:toggleConnection()
    if not self:isInstalled() then
        self:setupStart()
        return
    end
    self:invalidateState()
    if self:isRunning() and not needsSignIn(self:getDaemonStatus()) then
        self:disconnect()
    else
        self:connect()
    end
end

function NetBirdPlugin:onToggleNetBird()
    self:toggleConnection()
    return true
end

-- ─── connect / disconnect ─────────────────────────────────────────

--- after, if given, runs once this attempt connects, in place of the usual message.
-- It belongs to this attempt only: a later connect, or this one failing, drops it.
function NetBirdPlugin:connect(after)
    self._after_connect = nil
    if not self:hasNetwork() then
        UIManager:show(InfoMessage:new{
            text = _("No network connectivity.\nEnable Wi-Fi before starting NetBird."),
            timeout = 6,
        })
        return
    end

    self:stopLoginPolling()
    self:closeSignInQR()
    -- Stays up until connecting ends one way or another. Starting a daemon on an
    -- e-reader's CPU is slow, and a tap with no answer reads as a tap that failed.
    self:showWaitMessage(_("Connecting to NetBird…\nThis can take a minute. If you need to sign in, a QR code will appear here."))
    UIManager:forceRePaint()

    -- A daemon waiting on a sign-in, or left by a failed one, carries that state
    -- into the next attempt. Start over from clean.
    if self:isRunning() and needsSignIn(self:getDaemonStatus()) then
        self:runScript("stop")
    end
    local was_running = self:isRunning()
    local ok = self:runScript("start")
    local mode = self:runningMode()
    -- A daemon that just started is already reconnecting on its saved settings, and
    -- `up` would save new ones but answer "already connected" without applying them.
    -- Not in netstack mode: this early `down` leaves its SOCKS5 proxy answering
    -- "network unreachable", and the DNS settings it is for don't apply there.
    if ok and not was_running and mode == "tun" then
        self:runScript("down")
    end
    ok = ok and self:runScript("up")
    self:invalidateState()

    if not ok then
        self:closeWaitMessage()
        UIManager:show(InfoMessage:new{
            text = _("Failed to start NetBird.\nCheck the log:\n") .. self:getLogPath(),
            timeout = 8,
        })
        return
    end
    self:applyConnectMode(mode)
    self._after_connect = after
    self:startLoginPolling()
end

function NetBirdPlugin:disconnect()
    self:stopLoginPolling()
    self:closeSignInQR()
    self:runScript("stop")
    self:invalidateState()
    self:applyConnectMode(nil)
    self._after_connect = nil
    self.settings:saveSetting("want_connected", false)
    self.settings:flush()
    UIManager:show(InfoMessage:new{ text = _("NetBird disconnected"), timeout = 2 })
end

-- ─── sign-in ──────────────────────────────────────────────────────

--- No timeout: InfoMessage takes a timeout of 0 to mean close at the next chance.
function NetBirdPlugin:showWaitMessage(text)
    self:closeWaitMessage()
    self._wait_msg = InfoMessage:new{ text = text }
    UIManager:show(self._wait_msg)
end

function NetBirdPlugin:closeWaitMessage()
    if self._wait_msg then
        UIManager:close(self._wait_msg)
        self._wait_msg = nil
    end
end

--- `netbird up` prints the sign-in URL when it needs one, and exits with an error
-- line if it fails. The code to compare is in the URL, or next to it when it isn't.
function NetBirdPlugin:readUpOutput()
    local output = readFile(RUN_DIR .. "/up.log") or ""
    local url = output:match("https?://%S+")
    local code = url and url:match("user_code=([^&]+)") or output:match("enter the code (%S+)")
    return url, output:match("Error: ([^\n]+)"), code
end

--- UIManager:unschedule keys on the function reference, so the poll function is
-- stored rather than anonymous.
function NetBirdPlugin:startLoginPolling()
    self._poll_deadline = os.time() + LOGIN_POLL_TIMEOUT
    self._sign_in_offered = false
    self._poll_fn = function()
        -- First, because reading a file is instant and asking the daemon isn't. A QR
        -- code that is ready shouldn't wait for a subprocess on a slow CPU.
        local auth_url, up_error, code = self:readUpOutput()
        if auth_url and not self._sign_in_offered then
            self._sign_in_offered = true
            self:showSignInQRCode(auth_url, code)
            UIManager:scheduleIn(LOGIN_POLL_INTERVAL, self._poll_fn)
            return
        end
        local state = self:getDaemonStatus()
        self:invalidateState()
        if state == "Connected" then
            self:stopLoginPolling()
            self:onConnected()
        elseif up_error and self:isTunFailure(up_error) then
            -- The device node looked fine, but the interface can't be made. Keep the
            -- user connected in netstack mode rather than fail.
            logger.warn("NetBird: TUN failed, falling back to userspace mode:", up_error)
            NetBirdPlugin._tun_failed = true
            local after = self._after_connect
            self:stopLoginPolling()
            self:runScript("stop")
            self:invalidateState()
            self:connect(after)
        elseif up_error then
            self:stopLoginPolling()
            self:closeSignInQR()
            -- Otherwise a refused key would be used again by every later sign-in.
            if up_error:match("setup key") then
                os.remove(self:getSetupKeyPath())
            end
            self._after_connect = nil
            UIManager:show(InfoMessage:new{
                text = _("NetBird could not connect:\n") .. up_error,
                timeout = 10,
            })
        elseif os.time() >= self._poll_deadline then
            self:stopLoginPolling()
            self:closeSignInQR()
            self._after_connect = nil
            UIManager:show(InfoMessage:new{
                text = _("Timed out waiting for NetBird to connect."),
                timeout = 8,
            })
        else
            UIManager:scheduleIn(LOGIN_POLL_INTERVAL, self._poll_fn)
        end
    end
    UIManager:scheduleIn(LOGIN_POLL_INTERVAL, self._poll_fn)
end

--- An error from creating the TUN interface, in TUN mode, the first time only.
function NetBirdPlugin:isTunFailure(up_error)
    if NetBirdPlugin._tun_failed or self:runningMode() ~= "tun" then
        return false
    end
    local err = up_error:lower()
    return err:find("tun", 1, true) ~= nil or err:find("wt0", 1, true) ~= nil
        or err:find("interface", 1, true) ~= nil
end

function NetBirdPlugin:stopLoginPolling()
    self:closeWaitMessage()
    if self._poll_fn then
        UIManager:unschedule(self._poll_fn)
        self._poll_fn = nil
    end
end

--- A leftover setup key would be used instead of showing the code the user asked for.
function NetBirdPlugin:startQRLogin(after)
    os.remove(self:getSetupKeyPath())
    self:connect(after)
end

function NetBirdPlugin:onConnected()
    self:closeSignInQR()
    self.settings:saveSetting("want_connected", true)
    self.settings:flush()
    -- A setup key is only needed to register, and FAT cannot protect it. Don't
    -- keep a credential lying around once it has done its job.
    os.remove(self:getSetupKeyPath())
    local after = self._after_connect
    self._after_connect = nil
    if after then
        after()
    else
        UIManager:show(InfoMessage:new{ text = _("NetBird connected."), timeout = 3 })
    end
end

function NetBirdPlugin:closeSignInQR()
    if self._sign_in_qr then
        UIManager:close(self._sign_in_qr)
        self._sign_in_qr = nil
    end
end

--- The message stays behind the QR screen, so closing that doesn't lose the code.
-- If the QR code can't be built, the URL is still shown as selectable text.
function NetBirdPlugin:showSignInQRCode(auth_url, code)
    local code_line = code and (_("Code: ") .. code .. "\n") or ""
    self:showWaitMessage(code_line .. _("Waiting for you to approve this device on your phone…"))
    if has_qr then
        local built, qr = pcall(function()
            return NetBirdQR:new{
                url = auth_url,
                code = code,
                dismiss_callback = function() self._sign_in_qr = nil end,
            }
        end)
        if built then
            self._sign_in_qr = qr
            UIManager:show(qr)
            return
        end
    end
    logger.warn("NetBird: QR code unavailable, showing the sign-in URL as text")
    local TextViewer = require("ui/widget/textviewer")
    UIManager:show(TextViewer:new{
        title = _("NetBird sign-in URL"),
        text = code_line .. auth_url,
        justified = false,
    })
end

-- ─── install ──────────────────────────────────────────────────────

function NetBirdPlugin:installNetBird(after)
    local msg = InfoMessage:new{
        text = _("Downloading NetBird (15 MB, 40 MB once unpacked).\nThis may take a few minutes on slow Wi-Fi.\nAn update needs about 100 MB free.\nDO NOT CLOSE KOReader."),
    }
    UIManager:show(msg)
    UIManager:forceRePaint()

    -- The connection stays up during the download, so a failed update costs nothing.
    local result = self:readScript("install")
    UIManager:close(msg)

    if not result:match("OK%s*$") then
        UIManager:show(InfoMessage:new{
            text = _("Installation failed:\n") .. result:sub(1, 200),
            timeout = 8,
        })
        return
    end
    if after then
        after()
        return
    end
    -- A running daemon is still the old binary, so restart it on the new one.
    local was_running = self:isRunning()
    if was_running then
        self:runScript("stop")
        self:invalidateState()
    end
    if was_running or self.settings:isTrue("want_connected") then
        self:connect()
    else
        UIManager:show(InfoMessage:new{
            text = _("NetBird is installed.\nUse Set up NetBird to continue."),
            timeout = 8,
        })
    end
end

--- It deletes this device's identity, which no update can bring back. Ask first.
function NetBirdPlugin:confirmUninstall()
    UIManager:show(ConfirmBox:new{
        text = _("Uninstall NetBird?\n\nThis removes NetBird and this device's identity. To use NetBird again, you will need to sign in again."),
        ok_text = _("Uninstall"),
        ok_callback = function() self:uninstallNetBird() end,
    })
end

function NetBirdPlugin:uninstallNetBird()
    self:stopLoginPolling()
    self:closeSignInQR()
    self:runScript("uninstall")
    self:invalidateState()
    self:applyConnectMode(nil)
    self.settings:saveSetting("want_connected", false)
    self.settings:flush()
    UIManager:show(InfoMessage:new{
        text = _("NetBird removed, including this device's identity.\nYou can also delete the peer from your dashboard."),
        timeout = 6,
    })
end

-- ─── status and settings ──────────────────────────────────────────

function NetBirdPlugin:showStatus()
    local lines = {}
    if not self:isRunning() then
        table.insert(lines, _("Off"))
    else
        table.insert(lines, _("Mode: ") .. (self:runningMode() == "netstack"
            and _("userspace (KOReader only, IPs only)") or _("TUN")))
        local status = self:getStatus()
        if status then
            table.insert(lines, _("State: ") .. tostring(status.daemonStatus))
            if status.netbirdIp and status.netbirdIp ~= "" then
                table.insert(lines, _("IP: ") .. status.netbirdIp:gsub("/%d+$", ""))
            end
            if status.fqdn and status.fqdn ~= "" then
                table.insert(lines, _("Name: ") .. status.fqdn)
            end
            if type(status.peers) == "table" then
                table.insert(lines, _("Peers: ") .. tostring(status.peers.connected)
                    .. "/" .. tostring(status.peers.total))
            end
            local _url, up_error = self:readUpOutput()
            if up_error and status.daemonStatus ~= "Connected" then
                table.insert(lines, _("Last error: ") .. up_error)
            end
        end
    end
    table.insert(lines, _("Log: ") .. self:getLogPath())
    UIManager:show(InfoMessage:new{ text = table.concat(lines, "\n"), timeout = 10 })
end

--- A one-line text prompt. on_save gets the trimmed input.
function NetBirdPlugin:askText(title, input, hint, description, on_save)
    local dialog
    dialog = InputDialog:new{
        title = title,
        input = input,
        input_hint = hint,
        description = description,
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local value = (dialog:getInputText() or ""):gsub("^%s+", ""):gsub("%s+$", "")
                        UIManager:close(dialog)
                        on_save(value)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function NetBirdPlugin:configureSetupKey(after)
    self:askText(_("Setup key"), "", "XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX",
        _("From Setup Keys in your NetBird dashboard. It is deleted from the device once connected."),
        function(key)
            if key == "" then return end
            os.execute("mkdir -p " .. shellQuote(self.home_dir))
            local f = io.open(self:getSetupKeyPath(), "w")
            if not f then
                UIManager:show(InfoMessage:new{
                    text = _("Could not write ") .. self:getSetupKeyPath(),
                    timeout = 6,
                })
                return
            end
            f:write(key .. "\n")
            f:close()
            self:connect(after)
        end)
end

function NetBirdPlugin:configureManagementUrl(after)
    self:askText(_("Management server"), self:getManagementUrl(), DEFAULT_MANAGEMENT_URL,
        _("Only change this if you host NetBird yourself. Leave empty for NetBird Cloud. Changing it signs this device out."),
        function(url)
            self:saveManagementUrl(url)
            if after then after() end
        end)
end

--- A different server means a different network and a new peer, so the old identity
-- goes with it. That also leaves no saved settings for a starting daemon to act on.
function NetBirdPlugin:saveManagementUrl(url)
    local new_url = url ~= "" and url or DEFAULT_MANAGEMENT_URL
    if new_url == self:getManagementUrl() then return end
    self:stopLoginPolling()
    self:closeSignInQR()
    self:runScript("forget")
    self:invalidateState()
    self:applyConnectMode(nil)
    self.settings:saveSetting("management_url", url ~= "" and url or nil)
    self.settings:saveSetting("want_connected", false)
    self.settings:flush()
    UIManager:show(InfoMessage:new{
        text = _("Saved. Sign in to connect to this server."),
        timeout = 4,
    })
end

--- A daemon has to restart to turn DNS on or off, so reconnect right away instead
-- of leaving the user to work out why the name doesn't resolve yet.
function NetBirdPlugin:saveHostnames(value, after)
    self.settings:saveSetting("hostnames", value ~= "" and value or nil)
    self.settings:flush()
    if self:isRunning() then
        self:stopLoginPolling()
        self:runScript("stop")
        self:invalidateState()
        self:connect(after)
    end
end

function NetBirdPlugin:configureHostnames()
    self:askText(_("Domain resources"), self.settings:readSetting("hostnames") or "", "opds.example.com",
        _("NetBird domain resources you reach by name, separated by commas."),
        function(value) self:saveHostnames(value) end)
end

function NetBirdPlugin:onFlushSettings()
    self.settings:flush()
end

-- ─── setup ────────────────────────────────────────────────────────

--- One way through everything a new user needs. Each step leads to the next, and
-- every step also exists on its own under Advanced.
function NetBirdPlugin:setupStart()
    if self:isInstalled() then
        self:setupExplainMode()
        return
    end
    UIManager:show(ConfirmBox:new{
        text = _("NetBird isn't installed yet.\n\nDownload it now? It needs about 60 MB of free space while installing, and 40 MB after."),
        ok_text = _("Install"),
        ok_callback = function()
            self:installNetBird(function() self:setupExplainMode() end)
        end,
    })
end

--- What this device can do decides what the user has to set up, so say that plainly
-- before asking for anything.
function NetBirdPlugin:setupExplainMode()
    local tun = self:desiredMode() == "tun"
    UIManager:show(ConfirmBox:new{
        text = tun
            and _("This device runs NetBird in TUN mode.\n\nReach your OPDS server by name: in your NetBird dashboard, add it as a domain resource with a routing peer, and allow this device to reach it.\n\nIf the server is a NetBird peer itself, you can use its NetBird IP instead.")
            or _("This device runs NetBird in userspace mode, which has no domain names.\n\nReach your OPDS server by IP: install NetBird on the server so it becomes a peer, and allow this device to reach it. Then use its NetBird IP in KOReader."),
        ok_text = _("Continue"),
        ok_callback = function()
            if tun then
                self:setupAskHostname()
            else
                self:setupSignIn()
            end
        end,
    })
end

--- Asked before sign-in, so the first connection already has the DNS it needs.
function NetBirdPlugin:setupAskHostname()
    local current = self.settings:readSetting("hostnames") or ""
    self:askText(_("Domain resource"), current, "opds.example.com",
        _("The name of your NetBird domain resource. Separate several with commas. Leave empty if you use IPs."),
        function(value)
            if value == current then
                self:setupSignIn()
            elseif self:isRunning() then
                -- Already signed in: saving reconnects, and that finishes the setup.
                self:saveHostnames(value, function() self:setupFinish() end)
            else
                self:saveHostnames(value)
                self:setupSignIn()
            end
        end)
end

function NetBirdPlugin:setupSignIn()
    if self:isRunning() and self:getDaemonStatus() == "Connected" then
        self:setupFinish()
        return
    end
    local dialog
    local function choice(text, callback)
        return {{
            text = text,
            callback = function()
                UIManager:close(dialog)
                callback()
            end,
        }}
    end
    local function finish() self:setupFinish() end
    dialog = ButtonDialog:new{
        title = _("Sign in to NetBird"),
        buttons = {
            choice(_("Scan QR code"), function() self:startQRLogin(finish) end),
            choice(_("Use a setup key"), function() self:configureSetupKey(finish) end),
            choice(_("Server") .. ": " .. self:getManagementUrl(), function()
                self:configureManagementUrl(function() self:setupSignIn() end)
            end),
        },
    }
    UIManager:show(dialog)
end

--- The last thing the user needs is what to type into KOReader.
function NetBirdPlugin:setupFinish()
    local name = (self.settings:readSetting("hostnames") or ""):match("[^%s,]+")
    local where
    if name and self:runningMode() == "tun" then
        where = _("Add your OPDS catalog in KOReader with its usual address, such as:\n") .. "https://" .. name
    else
        where = _("Add your OPDS catalog in KOReader with the server's NetBird IP, such as:\n") .. "http://100.x.x.x:8080"
    end
    UIManager:show(InfoMessage:new{ text = _("NetBird is connected.\n\n") .. where })
end

-- ─── menu ─────────────────────────────────────────────────────────

function NetBirdPlugin:addToMainMenu(menu_items)
    local function refresh(touchmenu_instance)
        if touchmenu_instance and touchmenu_instance.updateItems then
            touchmenu_instance:updateItems()
        end
    end
    menu_items.netbird = {
        text = _("NetBird VPN"),
        sorting_hint = "network",
        sub_item_table = {
            {
                text_func = function() return self:connectionLabel() end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    self:toggleConnection()
                    refresh(touchmenu_instance)
                end,
            },
            { text = _("Set up NetBird"), callback = function() self:setupStart() end },
            { text = _("Status"), callback = function() self:showStatus() end },
            {
                text = _("Advanced"),
                sub_item_table = {
                    { text = _("Scan QR code"), callback = function() self:startQRLogin() end },
                    { text = _("Use a setup key"), callback = function() self:configureSetupKey() end },
                    {
                        text_func = function()
                            return _("Management server") .. ": " .. self:getManagementUrl()
                        end,
                        callback = function() self:configureManagementUrl() end,
                    },
                    {
                        text_func = function()
                            local names = self.settings:readSetting("hostnames")
                            return _("Domain resources") .. ": " .. (names or _("none"))
                        end,
                        enabled_func = function() return self:desiredMode() == "tun" end,
                        callback = function() self:configureHostnames() end,
                    },
                    {
                        text = _("Force userspace mode"),
                        help_text = _("Use this if TUN is unstable on your device. Takes effect on the next start."),
                        keep_menu_open = true,
                        checked_func = function() return self.settings:isTrue("force_userspace") end,
                        callback = function(touchmenu_instance)
                            self.settings:flipNilOrFalse("force_userspace")
                            self.settings:flush()
                            refresh(touchmenu_instance)
                        end,
                    },
                    { text = _("Install/Update NetBird"), callback = function() self:installNetBird() end },
                    { text = _("Uninstall NetBird"), callback = function() self:confirmUninstall() end },
                },
            },
        },
    }
end

return NetBirdPlugin
