local coroutine = require "coroutine"
local dns = require "dns"
local nmap = require "nmap"
local stdnse = require "stdnse"
local tab = require "tab"
local table = require "table"
local target = require "target"

description = [[
Enumerates various common service (SRV) records for a given domain name.
The service records contain the hostname, port and priority of servers for a given service.
The following services are enumerated by the script:
  - Active Directory Global Catalog
  - Exchange Autodiscovery
  - Kerberos KDC Service
  - Kerberos Passwd Change Service
  - LDAP Servers
  - SIP Servers
  - XMPP S2S
  - XMPP C2S
]]

---
-- @usage
-- nmap --script dns-srv-enum --script-args "dns-srv-enum.domain='example.com'"
--
-- @output
-- | dns-srv-enum:
-- |   Active Directory Global Catalog
-- |     service   prio  weight  host
-- |     3268/tcp  0     100     stodc01.example.com
-- |   Kerberos KDC Service
-- |     service  prio  weight  host
-- |     88/tcp   0     100     stodc01.example.com
-- |     88/udp   0     100     stodc01.example.com
-- |   Kerberos Password Change Service
-- |     service  prio  weight  host
-- |     464/tcp  0     100     stodc01.example.com
-- |     464/udp  0     100     stodc01.example.com
-- |   LDAP
-- |     service  prio  weight  host
-- |     389/tcp  0     100     stodc01.example.com
-- |   SIP
-- |     service   prio  weight  host
-- |     5060/udp  10    50      vclux2.example.com
-- |     5070/udp  10    50      vcbxl2.example.com
-- |     5060/tcp  10    50      vclux2.example.com
-- |     5060/tcp  10    50      vcbxl2.example.com
-- |   XMPP server-to-server
-- |     service   prio  weight  host
-- |     5269/tcp  5     0       xmpp-server.l.example.com
-- |     5269/tcp  20    0       alt2.xmpp-server.l.example.com
-- |     5269/tcp  20    0       alt4.xmpp-server.l.example.com
-- |     5269/tcp  20    0       alt3.xmpp-server.l.example.com
-- |_    5269/tcp  20    0       alt1.xmpp-server.l.example.com
--
-- @args dns-srv-enum.domain string containing the domain to query
-- @args dns-srv-enum.filter string containing the service to query
--       (default: all)

author = "Patrik Karlsson"
license = "Same as Nmap--See https://nmap.org/book/man-legal.html"
categories = {"discovery", "safe"}


local arg_domain = stdnse.get_script_args(SCRIPT_NAME .. ".domain")
local arg_filter = stdnse.get_script_args(SCRIPT_NAME .. ".filter")

prerule = function() return not(not(arg_domain)) end

local function parseSvcList(services)
  local i = 1
  return function()
    local svc = services[i]
    if ( svc ) then
      i=i + 1
    else
      return
    end
    return svc.name, svc.query
  end
end

local function parseSrvResponse(resp)
  local i = 1
  if ( resp.answers ) then
    table.sort(resp.answers,
      function(a, b)
        if ( a.SRV and b.SRV and a.SRV.prio and b.SRV.prio ) then
          return a.SRV.prio < b.SRV.prio
        end
      end
    )
  end
  return function()
    if ( not(resp.answers) or 0 == #resp.answers ) then  return end
    if ( not(resp.answers[i]) ) then
      return
    elseif ( resp.answers[i].SRV ) then
      local srv = resp.answers[i].SRV
      i = i + 1
      return srv.target, srv.port, srv.prio, srv.weight
    end
  end
end

local function checkFilter(services)
  if ( not(arg_filter) or "" == arg_filter or "all" == arg_filter ) then
    return true
  end
  for name, queries in parseSvcList(services) do
    if ( name == arg_filter ) then
      return true
    end
  end
  return false
end

local function doQuery(name, queries, result)
  local condvar = nmap.condvar(result)
  local svc_result = tab.new(4)
  tab.addrow(svc_result, "service", "prio", "weight", "host")
  for _, query in ipairs(queries) do
    local fqdn = ("%s.%s"):format(query, arg_domain)
    local status, resp = dns.query(fqdn, { dtype="SRV", retAll=true, retPkt=true } )
    for host, port, prio, weight in parseSrvResponse(resp) do
      if target.ALLOW_NEW_TARGETS then
        target.add(host)
      end
      local proto = query:sub(-3)
      tab.addrow(svc_result, ("%d/%s"):format(port, proto), prio, weight, host)
    end
  end
  if ( #svc_result ~= 1 ) then
    table.insert(result, { name = name, tab.dump(svc_result) })
  end
  condvar "signal"
end

action = function(host)

  local services = {
    { name = "Active Directory Global Catalog", query = {"_gc._tcp"} },
    { name = "Exchange Autodiscovery", query = {"_autodiscover._tcp"} },
    { name = "Kerberos KDC Service", query = {"_kerberos._tcp", "_kerberos._udp", 
                                              "_kerberos._tcp.dc._msdcs", "_kerberos._udp.dc._msdcs"} },
    { name = "Kerberos Password Change Service", query = {"_kpasswd._tcp", "_kpasswd._udp"} },
    { name = "LDAP", query = {"_ldap._tcp", "_ldap._tcp.pdc._msdcs", "_ldap._tcp.gc._msdcs",
                              "_ldap._tcp.dc._msdcs"} },
    { name = "SIP", query = {"_sip._udp", "_sip._tcp"} },
    { name = "XMPP server-to-server", query = {"_xmpp-server._tcp"} },
    { name = "XMPP client-to-server", query = {"_xmpp-client._tcp"} },
    { name = "Cisco Unified Communications Manager", query = {"_cisco-uds._tcp"} },
    { name = "Cisco Unified Presence", query = {"_cuplogin._tcp"} },
    { name = "Cisco VCS Expressway or Cisco Expressway-E server", query = {"_collab-edge._tls"} },
    { name = "Matrix", query = {"_matrix._tcp"} },
    { name = "STUN", query = {"_stun._tcp", "_stuns._tcp", "_stun._udp"} },
    { name = "TURN", query = {"_turn._tcp", "_turns._tcp", "_turn._udp"} },
    { name = "CalDAV/CardDAV", query = {"_carddav._tcp", "_caldav._tcp", "_carddavs._tcp", "_caldavs._tcp"} },
    { name = "Ceph Monitor", query = {"_ceph-mon._tcp"} },
    { name = "Minecraft", query = {"_minecraft._tcp"} },
    { name = "Puppet", query = {"_x-puppet-ca._tcp", "_x-puppet._tcp"} },
    { name = "Teamspeak", query = {"_ts3._udp"} },
    { name = "IMAP", query = {"_imap._tcp", "_imaps._tcp"} },
    { name = "POP3", query = {"_pop3._tcp", "_pop3s._tcp"} },
    { name = "SMTP", query = {"_submission._tcp"} },
    { name = "Jabber", query = {"_jabber._tcp"} },
    { name = "HP Device Manager", query = {"_hpdm-gateway._tcp"} },
  }

  if ( not(checkFilter(services)) ) then
    return stdnse.format_output(false, ("Invalid filter (%s) was supplied"):format(arg_filter))
  end

  local threads, result = {}, {}
  for name, queries in parseSvcList(services) do
    if ( not(arg_filter) or 0 == #arg_filter or
      "all" == arg_filter or arg_filter == name ) then
      local co = stdnse.new_thread(doQuery, name, queries, result)
      threads[co] = true
    end
  end

  local condvar = nmap.condvar(result)
  repeat
    for t in pairs(threads) do
      if ( coroutine.status(t) == "dead" ) then threads[t] = nil end
    end
    if ( next(threads) ) then
      condvar "wait"
    end
  until( next(threads) == nil )

  table.sort(result, function(a,b) return a.name < b.name end)

  return stdnse.format_output(true, result)
end
