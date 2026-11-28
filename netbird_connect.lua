--- Get KOReader's connections to where NetBird can carry them.
--
-- KOReader can't be pointed at NetBird in the two cases below, so this patches
-- connect() on LuaSocket's TCP class, which HTTP and HTTPS both go through. The
-- caller still sees its original hostname, so a reverse proxy gets the right Host
-- header and SNI. Anything else is left alone.
--
-- Userspace mode: NetBird's peers, and addresses behind its routing peers, are only
-- reachable through a SOCKS5 proxy on loopback, and KOReader can use an HTTP proxy
-- but not SOCKS5. The proxy only takes addresses, so a server behind a routing peer
-- is reached by name through a fixed name=IP entry.
--
-- Listed hostnames: a NetBird domain resource only gets its route when NetBird's
-- own DNS server answers for it. The system's DNS can't be relied on to ask it,
-- because NetBird can't change resolv.conf on a read-only rootfs like the Kindle's.
local socket = require("socket")

local NetBirdConnect = {
    socks_enabled = false,
    proxy_host = "127.0.0.1",
    proxy_port = 1080, -- NetBird's default NB_SOCKS5_LISTENER_PORT
    hostnames = {}, -- set of lowercase names to resolve through NetBird
    routes = { names = {}, ranges = {} }, -- userspace mode, from parseRoutes
    dns_timeout = 5,
    dns_host = nil, -- found once through find_dns_host, then kept
    find_dns_host = nil, -- set by main.lua; returns NetBird's DNS address, or nil
    is_running = function() return false end, -- set by main.lua; whether a daemon is up
}

--- An IPv4 address as a number, or nil for anything else, hostnames included.
local function parseIPv4(host)
    if type(host) ~= "string" then return nil end
    local a, b, c, d = host:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    a, b, c, d = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
    if not a or a > 255 or b > 255 or c > 255 or d > 255 then return nil end
    return ((a * 256 + b) * 256 + c) * 256 + d
end

local function range(ip, bits)
    local size = 2 ^ (32 - bits)
    return { ip = ip - ip % size, size = size }
end

local function inRange(ip, r)
    return ip - ip % r.size == r.ip
end

-- NetBird hands out peer addresses from the CGNAT range.
local NETBIRD_RANGE = range(parseIPv4("100.64.0.0"), 10)

--- Routed addresses from a list separated by commas or spaces. Each entry is a
-- range (192.168.1.0/24), an address, or name=address for a server reached by
-- name. Returns the routes, and the entries that are none of these.
function NetBirdConnect.parseRoutes(text)
    local routes, bad = { names = {}, ranges = {} }, {}
    for entry in (text or ""):gmatch("[^%s,]+") do
        local name, address = entry:match("^([%w%.%-]+)=(.+)$")
        local addr, bits = entry:match("^([%d%.]+)/(%d+)$")
        if name and parseIPv4(address) then
            routes.names[name:lower()] = parseIPv4(address)
        elseif addr and parseIPv4(addr) and tonumber(bits) <= 32 then
            table.insert(routes.ranges, range(parseIPv4(addr), tonumber(bits)))
        elseif parseIPv4(entry) then
            table.insert(routes.ranges, range(parseIPv4(entry), 32))
        else
            table.insert(bad, entry)
        end
    end
    return routes, bad
end

--- The address to reach through the proxy, or nil to connect the regular way.
local function proxiedAddress(host)
    local named = NetBirdConnect.routes.names[host:lower()]
    if named then return named end
    local ip = parseIPv4(host)
    if not ip then return nil end
    if inRange(ip, NETBIRD_RANGE) then return ip end
    for _, r in ipairs(NetBirdConnect.routes.ranges) do
        if inRange(ip, r) then return ip end
    end
    return nil
end

--- RFC 1928 CONNECT, no authentication. The socket's timeout, if any, applies.
local function handshake(sock, port, ip)
    local ok, err = sock:send("\5\1\0")
    if not ok then return nil, err end
    local reply
    reply, err = sock:receive(2)
    if not reply then return nil, err end
    if reply ~= "\5\0" then return nil, "SOCKS5 proxy refused the handshake" end

    ok, err = sock:send(string.char(5, 1, 0, 1,
        math.floor(ip / 16777216), math.floor(ip / 65536) % 256, math.floor(ip / 256) % 256, ip % 256,
        math.floor(port / 256), port % 256))
    if not ok then return nil, err end
    reply, err = sock:receive(4)
    if not reply then return nil, err end
    if reply:byte(2) ~= 0 then
        return nil, "SOCKS5 connect failed, code " .. reply:byte(2)
    end

    -- Drain the bound address that closes the reply; its length depends on its type.
    local atyp = reply:byte(4)
    if atyp == 1 then
        reply, err = sock:receive(6)
    elseif atyp == 4 then
        reply, err = sock:receive(18)
    else
        return nil, "SOCKS5 reply has an unexpected address type"
    end
    if not reply then return nil, err end
    return 1
end

--- Returns the position after a DNS name, or nil if the message is cut short.
local function skipName(msg, pos)
    while true do
        local len = msg:byte(pos)
        if not len then return nil end
        if len == 0 then return pos + 1 end
        if len >= 192 then return pos + 2 end -- compressed: a pointer ends the name
        pos = pos + len + 1
    end
end

--- Returns the first A record in a DNS reply. CNAMEs are skipped: a recursive
-- server sends the addresses they lead to in the same reply.
local function parseAnswer(msg, id)
    if #msg < 12 or msg:sub(1, 2) ~= id then return nil, "invalid reply" end
    local rcode = msg:byte(4) % 16
    if rcode ~= 0 then return nil, "DNS error " .. rcode end
    local count = msg:byte(7) * 256 + msg:byte(8)
    local pos = skipName(msg, 13)
    pos = pos and pos + 4 -- QTYPE and QCLASS
    for _ = 1, count do
        pos = pos and skipName(msg, pos)
        if not pos or #msg < pos + 9 then return nil, "invalid reply" end
        local rtype = msg:byte(pos) * 256 + msg:byte(pos + 1)
        local rdlength = msg:byte(pos + 8) * 256 + msg:byte(pos + 9)
        pos = pos + 10
        if rtype == 1 and rdlength == 4 and #msg >= pos + 3 then
            return string.format("%d.%d.%d.%d", msg:byte(pos, pos + 3))
        end
        pos = pos + rdlength
    end
    return nil, "no address"
end

--- Where NetBird answers DNS, for a peer address like 100.92.1.5/16. With userspace
-- WireGuard it opens no socket: it catches packets inside the tunnel, sent to port
-- 53 of the last usable address of the network (GetLastIPFromNetwork(network, 1)).
function NetBirdConnect.dnsAddressFor(peer_address)
    local a, b, c, d, bits = (peer_address or ""):match("^(%d+)%.(%d+)%.(%d+)%.(%d+)/(%d+)$")
    if not a then return nil end
    local ip = a * 16777216 + b * 65536 + c * 256 + d
    local size = 2 ^ (32 - bits)
    local last = ip - ip % size + size - 2
    return string.format("%d.%d.%d.%d",
        math.floor(last / 16777216), math.floor(last / 65536) % 256, math.floor(last / 256) % 256, last % 256)
end

local function queryOnce(host, dns_host)
    local id = string.char(math.random(0, 255), math.random(0, 255))
    local labels = {}
    for label in host:gmatch("[^.]+") do
        labels[#labels + 1] = string.char(#label) .. label
    end
    local query = id .. "\1\0\0\1\0\0\0\0\0\0" .. table.concat(labels) .. "\0\0\1\0\1"

    local udp, err = socket.udp()
    if not udp then return nil, err end
    udp:settimeout(NetBirdConnect.dns_timeout)
    udp:setpeername(dns_host, 53)
    udp:send(query)
    local reply
    reply, err = udp:receive()
    udp:close()
    if not reply then return nil, err end
    return parseAnswer(reply, id)
end

--- Asks NetBird's DNS server. The asking is what makes NetBird add the route, so
-- this happens on every connect instead of caching the answer. A second try gives a
-- routing peer that was idle the moment it needs to wake up.
local function resolve(host)
    local dns_host = NetBirdConnect.dns_host or NetBirdConnect.find_dns_host()
    if not dns_host then return nil, "NetBird isn't connected yet" end
    NetBirdConnect.dns_host = dns_host
    local ip, err = queryOnce(host, dns_host)
    if not ip then
        socket.sleep(1)
        ip, err = queryOnce(host, dns_host)
    end
    return ip, err
end

--- Called once, when the module loads. The method table is shared by every TCP
-- socket in the process, so the fields above decide per connection.
local function install()
    local master = socket.tcp()
    local methods = getmetatable(master).__index
    master:close()

    local orig_connect = methods.connect
    methods.connect = function(sock, host, port, ...)
        -- Both cases fail closed: if NetBird can't help, the connection fails
        -- rather than going out over the regular network. A listed name only while
        -- a daemon runs, though: with NetBird off, the regular network is the way
        -- there, as at home, whatever state an earlier start left behind.
        if type(host) == "string" and NetBirdConnect.hostnames[host:lower()]
                and NetBirdConnect.is_running() then
            local ip, err = resolve(host:lower())
            if not ip then
                sock:close()
                return nil, "NetBird could not resolve " .. host .. ": " .. tostring(err)
            end
            return orig_connect(sock, ip, port, ...)
        end

        local ip
        if NetBirdConnect.socks_enabled and type(host) == "string" then
            ip = proxiedAddress(host)
        end
        if not ip then
            return orig_connect(sock, host, port, ...)
        end
        local ok, err = orig_connect(sock, NetBirdConnect.proxy_host, NetBirdConnect.proxy_port)
        if ok then
            ok, err = handshake(sock, tonumber(port), ip)
        end
        if not ok then
            sock:close()
            return nil, err
        end
        return 1
    end
end

install()

return NetBirdConnect
