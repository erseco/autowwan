#!/usr/bin/env lua
require("uci")
require("iwinfo")

--{{{ helper functions
---{{{ split
function split(str, pat)
   local t = {}  -- NOTE: use {n = 0} in Lua-5.0
   local fpat = "(.-)" .. pat
   local last_end = 1
   local s, e, cap = str:find(fpat, 1)
   while s do
      if s ~= 1 or cap ~= "" then
     table.insert(t,cap)
      end
      last_end = e+1
      s, e, cap = str:find(fpat, last_end)
   end
   if last_end <= #str then
      cap = str:sub(last_end)
      table.insert(t, cap)
   end
   return t
end
---}}}
---{{{ typify
function typify(t)
    for k, v in pairs(t) do
        vn = tonumber(v)
        if vn then t[k] = vn end
        if v == 'false' then v = false end
    end
    return t
end
---}}}
---{{{ pref_sort 
function pref_sort(a, b)
    local ascore = presets[a.ssid].score
    local bscore = presets[b.ssid].score
    if ascore or bscore then
        return (ascore or 0) > (bscore or 0)
    else
        return a.signal > b.signal
    end
end
---}}}
---{{{ sleep 
function sleep(t)
    os.execute("sleep "..t)
end
---}}}
---{{{ pread 
function pread(cmd)
    local f = io.popen(cmd)
    if not f then return end
    local output = f:read("*a")
    f:close()
    return output
end
---}}}
---{{{ fsize 
function fsize(file)
    local f = io.open(file)
    local size = f:seek("end")
    f:close()
    return size
end
---}}}
--}}}
--{{{ log functions
function log(msg, l, nonl)
    local l = l or logs.info
    if l.level > log_level then return end
    local nl = (nonl and "") or "\n"
    local time = os.date("%Y-%m-%d %H:%M:%S")
    local stamp = time .. " autowwan." .. l.header .. ": "
    io.stdout:write(stamp .. msg .. nl)
end
function log_result(msg, l)
    local l = l or logs.info
    if l.level > log_level then return end
    io.stdout:write(msg.."\n")
end
--}}}
--{{{ uci functions
function get_uci_section()
    uwifi:load("wireless")
    uwifi:foreach("wireless", "wifi-iface", function(s)
        if s.autowwan and s.mode == "sta" then cfg.section=s[".name"] end end)

    if not cfg.section then
        log("no suitable interfaces found", logs.err)
        os.exit(1)
    end
end

function update_config()
    ucfg:load("autowwan")
    log("reading config", logs.info)
    cfg = ucfg:get_all("autowwan.config")
    ignored = {}
    for i, ssid in ipairs(split(cfg.ignore_ssids, ",")) do
        ignored[ssid] = true
    end
    cfg = typify(cfg)
    for k, v in pairs(defaults) do
        if not cfg[k] then cfg[k] = v end
    end
    get_uci_section()
end

function update_presets()
    ucfg:load("autowwan")
    log("reading presets", logs.info)
    presets = {}
    ucfg:foreach("autowwan", "networks", function(net) presets[net.ssid] = typify(net) end)
end
--}}}
--{{{ net functions
---{{{ update_connectable
function update_connectable()
    connectable = {}
    for i, ap in ipairs(range) do
        if not (ignored[ap.ssid] or (presets[ap.ssid] and presets[ap.ssid].ignore)) then
            if (not ap.encryption.enabled) and cfg.join_open then
                table.insert(connectable, ap)
                presets[ap.ssid] = { encryption = "none", key = "", score = 0 }
            elseif presets[ap.ssid] then
                table.insert(connectable, ap)
            end
        end
    end
    table.sort(connectable, pref_sort)
    log_result("found "..#connectable.." out of "..#range, logs.info)
end
---}}}
---{{{ update_range
function update_range()
    log("scanning: ", logs.info, 1)
    os.execute("ifconfig " .. cfg.iface .. " up")
    range = iwinfo.nl80211.scanlist(cfg.iface)
end
---}}}
---{{{ ping
function ping(host, opts)
    local out = pread(string.format("ping %s %s 2>/dev/null", opts, host))
    return tonumber(out:match("/(%d+%.%d+)/"))
end
---}}}
---{{{ connect
function connect(ap)
    get_uci_section()
    os.execute("ifdown wan")
    log("connecting to ap: "..ap.ssid, logs.info)
    uwifi:set("wireless", cfg.section, "ssid", ap.ssid)
    uwifi:set("wireless", cfg.section, "encryption", presets[ap.ssid].encryption)
    uwifi:set("wireless", cfg.section, "key", presets[ap.ssid].key)
    uwifi:save("wireless")
    uwifi:commit("wireless")
    os.execute("wifi >& /dev/null")
    sleep(cfg.conn_timeout)
    for i, test in ipairs(tests) do
        if test.conn then
            local result = test.f(test)
            if not result then return end
        end
    end
    log("connected!")
    return true
end
---}}}
---{{{ reconnect
function reconnect()
    log("reconnecting")
    local connected
    while not connected do
        update_config()
        update_presets()
        update_range()
        update_connectable()
        for i, ap in ipairs(connectable) do
            connected = connect(ap)
            if connected then break end
        end
    end
end
---}}}
--}}}
--{{{ test functions
---{{{ ping_test
function ping_test(arg)
    log("ping test - ", logs.info, 1)
    local p = ping(arg.host, arg.opts)
    update_stats(arg, p)
    if p then
        log_result(string.format("ok [%s, %.0fms, avg %.0fms, loss %.0f%%]", arg.host, p, stats[arg].avg, stats[arg].loss))
    else
        log_result("failed!")
    end
    return p
end
---}}}
---{{{ wifi_test
function wifi_test(arg)
    log("wifi test - ", logs.info, 1)
    local q = iwinfo.nl80211.quality(cfg.iface)
    local qmax = iwinfo.nl80211.quality_max(cfg.iface)
    local p = math.floor((q*100)/qmax)
    update_stats(arg, p)
    if 
        iwinfo.nl80211.bssid(cfg.iface) and q > 0
    then 
        log_result(string.format("ok [%s, %s%%, avg %.0f%%]", iwinfo.nl80211.ssid(cfg.iface), p, stats[arg].avg))
        return p
    else
        log_result("failed!")
    end
end
---}}}
---{{{ ip_test
function ip_test()
    log("ip test   - ", logs.info, 1)
    wan = ustate:get_all("network", "wan")
    if not wan then
        log_result("failed [interface down]")
    elseif not wan.up then
        log_result("failed [not connected]")
    elseif not wan.ipaddr then
        log_result("failed [no IP address]")
    elseif not wan.gateway then
        log_result("failed [no gateway]")
    else
        log_result(string.format("ok [%s/%s gw %s]", wan.ipaddr, wan.netmask, wan.gateway))
        return wan
    end
end
---}}}
---{{{ dns_test
function dns_test(arg)
    log("dns test  - ", logs.info, 1)
    local out = pread("nslookup "..arg.host)
    local name, addr = out:match("Name:.-([%w%p]+).*Address 1: (%d+%.%d+%.%d+%.%d+)")
    if name and addr then
        log_result(string.format("ok [%s -> %s]", name, addr))
        return true
    else
        log_result("failed")
    end
end
---}}}
---{{{ http_test
function http_test(arg)
    log("http test - ", logs.info, 1)
    local start = os.time()
    local fn = arg.dest .. "/http_test"
    os.execute(string.format("wget -O%s %s >& /dev/null", fn, arg.url))
    local finish = os.time()
    local md5 = pread("md5sum "..fn):match("(%w+)")
    local bw = fsize(fn)/(finish-start)/1024
    update_stats(arg, bw)
    if arg.md5 == md5 then
        log_result(string.format("ok [md5sum good, %.0fKB/s, avg %0.fKB/s]", bw, stats[arg].avg))
        return true
    else
        log_result("failed [md5sum mismatch]")
    end
    os.execute("rm "..fn)
end
---}}}
--}}}
--{{{ stat functions
function update_stats(arg, res)
    local stat = stats[arg] or {}
    table.insert(stat, 1, res or "#fail#")
    if #stat > cfg.stat_buffer then
        table.remove(stat, cfg.stat_buffer)
    end
    local lost = 0
    local total = 0
    for i, res in ipairs(stat) do
        if res ~= "#fail#" then
            total = total + res
        else
            lost = lost + 1
        end
    end
    stat.loss = (lost*100)/#stat
    stat.avg = total/(#stat-lost)
    stats[arg] = stat
end
--}}}

--{{{ defaults
defaults = {
    iface = "wlan0",
    join_open = true,
    ignore_ssids = "IgnoreMe,AndMe,MeToo",
    interval = 1,
    conn_timeout = 10,
    stat_buffer = 50,
}

tests = {
    { f = wifi_test, conn = true, interval = 1, retry_limit = 1 },
    { f = ip_test, conn = true },
    { f = ping_test, conn = true, interval = 1, retry_limit = 10,
        host = "8.8.8.8",
        opts = "-W 5 -c 1" },
    { f = dns_test, conn = true, host = "google.com" },
    { f = http_test, conn = true,
        url = "http://www.kernel.org/pub/linux/kernel/v2.6/ChangeLog-2.6.9",
        md5 = "b6594bd05e24b9ec400d742909360a2c",
        dest ="/tmp" },
}

logs = {
    err     = { header = "error",     level = 0 },
    warn    = { header = "warning", level = 1 },
    info    = { header = "info",     level = 2 },
    dbg     = { header = "debug",   level = 3 },
}

log_level = 2

--}}}
--{{{ init
uwifi = uci.cursor()
ucfg = uci.cursor()
ustate = uci.cursor(ni, "/var/state")

update_config()

stats = {}
iter = 0
--}}}
--{{{ main loop
while true do
    for i, test in ipairs(tests) do
        if test.interval and math.fmod(iter, test.interval) == 0 then
            local result = test.f(test)
            if not result then
                test.failed = (test.failed or 0) + 1
                if test.failed >= test.retry_limit then
                    log("reached retry limit")
                    stats = {}
                    iter = 0
                    reconnect()
                    break
                end
            else
                test.failed = 0
            end
        end
    end
    iter = iter + 1
    sleep(cfg.interval)
end
--}}}
-- vim: foldmethod=marker:filetype=lua:expandtab:shiftwidth=4:tabstop=4:softtabstop=4
