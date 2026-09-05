--!nonstrict
-- VPN Manager service: owns NetworkManager polling, VPN connect/disconnect/
-- import/delete, trusted-network tracking and the auto-connect/disconnect
-- decision. Every other entry (bar, panel, shortcut) only reads published
-- state and sends commands through noctalia.state.set("vpn.cmd", ...).

noctalia.setUpdateInterval(1000)

-- ── constants ─────────────────────────────────────────────────────────────

local SERVICE_TYPE_LABELS = {
  ["org.freedesktop.NetworkManager.openvpn"] = "OpenVPN",
  ["org.freedesktop.NetworkManager.openconnect"] = "Cisco AnyConnect (OpenConnect)",
  ["org.freedesktop.NetworkManager.vpnc"] = "Cisco VPN (vpnc)",
  ["org.freedesktop.NetworkManager.l2tp"] = "L2TP/IPsec",
  ["org.freedesktop.NetworkManager.pptp"] = "PPTP",
  ["org.freedesktop.NetworkManager.strongswan"] = "IPsec/IKEv2 (strongSwan)",
  ["org.freedesktop.NetworkManager.sstp"] = "SSTP",
  ["org.freedesktop.NetworkManager.fortisslvpn"] = "Fortinet SSL VPN",
  ["org.freedesktop.NetworkManager.ssh"] = "SSH",
}

-- service-type suffix -> Arch package name, for "install this to add support" hints.
local PACKAGE_HINTS = {
  openvpn = "networkmanager-openvpn",
  openconnect = "networkmanager-openconnect",
  vpnc = "networkmanager-vpnc",
  l2tp = "networkmanager-l2tp",
  pptp = "networkmanager-pptp",
  strongswan = "networkmanager-strongswan",
  sstp = "networkmanager-sstp",
  fortisslvpn = "networkmanager-fortisslvpn",
}

local VPN_PLUGIN_DIRS = { "/usr/lib64/NetworkManager/VPN", "/usr/lib/NetworkManager/VPN" }

-- ── small helpers ────────────────────────────────────────────────────────

local function log(msg)
  noctalia.log(`vpn-manager: {msg}`)
end

local function trim(s)
  return noctalia.string.trim(s or "")
end

local function firstLine(s)
  s = trim(s)
  local nl = s:find("\n")
  if nl ~= nil then
    return s:sub(1, nl - 1)
  end
  return s
end

local function clampInt(v, lo, hi, default)
  v = tonumber(v)
  if v == nil then
    return default
  end
  v = math.floor(v)
  if v < lo then
    return lo
  end
  if v > hi then
    return hi
  end
  return v
end

local function cfgBool(key, default)
  local v = noctalia.getConfig(key)
  if type(v) == "boolean" then
    return v
  end
  return default
end

local function cfgInt(key, lo, hi, default)
  return clampInt(noctalia.getConfig(key), lo, hi, default)
end

local function run(argv, onDone, timeoutMs)
  local accepted = noctalia.runAsync(argv, onDone, timeoutMs or 15000)
  if not accepted then
    log("failed to start: " .. table.concat(argv, " "))
    if onDone ~= nil then
      onDone({ exitCode = -1, stdout = "", stderr = "failed to start process", timedOut = false })
    end
  end
end

-- Sequentially maps items through an async fn(item, done), then calls onDone(results).
local function mapAsync(items, fn, onDone)
  local results = {}
  local i = 0
  local function step()
    i += 1
    if i > #items then
      onDone(results)
      return
    end
    fn(items[i], function(result)
      results[i] = result
      step()
    end)
  end
  step()
end

local function friendlyProtocol(ctype, serviceType)
  if ctype == "wireguard" then
    return "WireGuard"
  end
  if type(serviceType) == "string" and SERVICE_TYPE_LABELS[serviceType] ~= nil then
    return SERVICE_TYPE_LABELS[serviceType]
  end
  if type(serviceType) == "string" and serviceType ~= "" then
    return (serviceType:gsub("^org%.freedesktop%.NetworkManager%.", ""))
  end
  return "VPN"
end

local function packageHintFor(typeArg)
  local hint = PACKAGE_HINTS[typeArg]
  if hint ~= nil then
    return " " .. noctalia.tr("notifications.install_hint", { package = hint })
  end
  return ""
end

local function detectImportType(content)
  if type(content) ~= "string" then
    return nil
  end
  if content:match("%[Interface%]") and content:match("%[Peer%]") then
    return "wireguard"
  end
  if content:match("^%s*client") or content:match("\nremote%s+%S") or content:match("<ca>") or content:match("%-%-%-%-%-BEGIN CERTIFICATE") then
    return "openvpn"
  end
  return nil
end

-- ── persistent data (trusted networks, default VPN, auto-started tracking) ──

local data = {
  trustedNetworks = {},
  defaultVpnUuid = "",
  autoStartedUuid = "",
}

local function dataPath()
  local dir = noctalia.pluginDataDir()
  if dir == nil then
    return nil
  end
  return dir .. "/data.json"
end

local function saveData()
  local path = dataPath()
  if path == nil then
    return
  end
  local encoded = noctalia.json.encode(data)
  if encoded ~= nil then
    noctalia.writeFile(path, encoded)
  end
end

local function loadData()
  local path = dataPath()
  if path == nil then
    return
  end
  local raw = noctalia.readFile(path)
  if raw == nil then
    return
  end
  local decoded = noctalia.json.decode(raw)
  if type(decoded) ~= "table" then
    return
  end
  if type(decoded.trustedNetworks) == "table" then
    data.trustedNetworks = decoded.trustedNetworks
  end
  if type(decoded.defaultVpnUuid) == "string" then
    data.defaultVpnUuid = decoded.defaultVpnUuid
  end
  if type(decoded.autoStartedUuid) == "string" then
    data.autoStartedUuid = decoded.autoStartedUuid
  end
end

local function isTrusted(name)
  for _, n in ipairs(data.trustedNetworks) do
    if n == name then
      return true
    end
  end
  return false
end

-- ── installed VPN plugin detection ──────────────────────────────────────

local function publishAvailableProtocols()
  local available = { wireguard = true } -- always native/built in
  for _, dir in ipairs(VPN_PLUGIN_DIRS) do
    local entries = noctalia.listDir(dir)
    if entries ~= nil then
      for _, entry in ipairs(entries) do
        local key = entry:match("^nm%-(.+)%-service%.name$")
        if key ~= nil then
          available[key] = true
        end
      end
    end
  end
  noctalia.state.set("vpn.availableProtocols", available)
end

-- ── live state (last refresh results) ───────────────────────────────────

local lastVpnRows = {}
local refreshInFlight = false
local opInFlight = {} -- uuid -> true while a connect/disconnect/delete is running
local untrustedStreak = 0
local trustedStreak = 0
local tickCount = 0

local function nameForUuid(uuid)
  for _, row in ipairs(lastVpnRows) do
    if row.uuid == uuid then
      return row.name
    end
  end
  return nil
end

local function publishConnections()
  local rows = {}
  local activeNames = {}
  for _, row in ipairs(lastVpnRows) do
    table.insert(rows, {
      uuid = row.uuid,
      name = row.name,
      protocol = row.protocol,
      ctype = row.ctype,
      active = row.active,
      isDefault = row.uuid == data.defaultVpnUuid,
      busy = opInFlight[row.uuid] == true,
    })
    if row.active then
      table.insert(activeNames, row.name)
    end
  end
  table.sort(rows, function(a, b)
    return a.name:lower() < b.name:lower()
  end)
  noctalia.state.set("vpn.connections", rows)
  noctalia.state.set("vpn.status", {
    anyActive = #activeNames > 0,
    activeNames = activeNames,
  })
end

local function publishTrust()
  noctalia.state.set("vpn.trustedNetworks", data.trustedNetworks)
  noctalia.state.set("vpn.defaultVpnUuid", data.defaultVpnUuid)
end

-- ── connect / disconnect / delete / import ──────────────────────────────

local function refreshAll()
  -- fwd declared below; assigned once defined
end

local function connectUuid(uuid, isAuto)
  if uuid == nil or uuid == "" or opInFlight[uuid] then
    return
  end
  opInFlight[uuid] = true
  publishConnections()
  run({ "nmcli", "connection", "up", "uuid", uuid }, function(result)
    opInFlight[uuid] = nil
    if result.exitCode == 0 then
      if isAuto then
        data.autoStartedUuid = uuid
        saveData()
        if cfgBool("notify_on_autoswitch", true) then
          noctalia.notify(noctalia.tr("title"), noctalia.tr("notifications.connected_untrusted", { name = nameForUuid(uuid) or noctalia.tr("title") }))
        end
      end
    else
      local msg = firstLine(result.stderr)
      if msg:match("Secrets were required") then
        msg = msg .. " Open it once in nmtui or nm-connection-editor to save the password, then it will connect automatically."
      end
      noctalia.notifyError(noctalia.tr(isAuto and "notifications.auto_connect_failed" or "notifications.connect_failed"), msg)
    end
    refreshAll()
  end, 25000)
end

local function disconnectUuid(uuid, isAuto)
  if uuid == nil or uuid == "" or opInFlight[uuid] then
    return
  end
  opInFlight[uuid] = true
  publishConnections()
  run({ "nmcli", "connection", "down", "uuid", uuid }, function(result)
    opInFlight[uuid] = nil
    if uuid == data.autoStartedUuid then
      data.autoStartedUuid = ""
      saveData()
    end
    if result.exitCode == 0 then
      if isAuto and cfgBool("notify_on_autoswitch", true) then
        noctalia.notify(noctalia.tr("title"), noctalia.tr("notifications.disconnected_trusted"))
      end
    else
      noctalia.notifyError(noctalia.tr(isAuto and "notifications.auto_disconnect_failed" or "notifications.disconnect_failed"), firstLine(result.stderr))
    end
    refreshAll()
  end, 25000)
end

local function deleteUuid(uuid)
  if uuid == nil or uuid == "" then
    return
  end
  run({ "nmcli", "connection", "delete", "uuid", uuid }, function(result)
    if result.exitCode ~= 0 then
      noctalia.notifyError(noctalia.tr("notifications.delete_failed"), firstLine(result.stderr))
    else
      if data.defaultVpnUuid == uuid then
        data.defaultVpnUuid = ""
      end
      if data.autoStartedUuid == uuid then
        data.autoStartedUuid = ""
      end
      saveData()
    end
    refreshAll()
  end)
end

local function finishImport(path, typeArg, isTemp)
  local function cleanup()
    if isTemp then
      noctalia.removeFile(path)
    end
  end

  local function doImport(resolvedType)
    if resolvedType == nil then
      noctalia.notifyError(
        noctalia.tr("notifications.import_failed"),
        noctalia.tr("notifications.detect_failed")
      )
      cleanup()
      return
    end
    run({ "nmcli", "connection", "import", "type", resolvedType, "file", path }, function(result)
      cleanup()
      log(`import result exitCode={result.exitCode} stdout={result.stdout:gsub("\n", "\\n")} stderr={result.stderr:gsub("\n", "\\n")}`)
      if result.exitCode ~= 0 then
        noctalia.notifyError(noctalia.tr("notifications.import_failed"), firstLine(result.stderr) .. packageHintFor(resolvedType))
        return
      end
      -- Newly imported connections default to autoconnect=yes (NM connects them at
      -- boot / whenever the device is available); this plugin drives activation
      -- itself, so turn that off to avoid two different things deciding when the
      -- VPN comes up.
      local newName = result.stdout:match("Connection '([^']+)'")
      local newUuid = result.stdout:match("%(([%w%-]+)%)")
      if newUuid ~= nil then
        run({ "nmcli", "connection", "modify", "uuid", newUuid, "connection.autoconnect", "no" }, function() end)
      end
      noctalia.notify(noctalia.tr("title"), noctalia.tr("notifications.imported", { name = newName or noctalia.tr("notifications.a_connection") }))
      refreshAll()
    end, 20000)
  end

  if typeArg ~= nil and typeArg ~= "" then
    doImport(typeArg)
  else
    local content = noctalia.readFile(path)
    doImport(detectImportType(content))
  end
end

local function importFromPath(path, typeArg)
  path = trim(path)
  if path == "" then
    noctalia.notifyError(noctalia.tr("notifications.import_failed"), noctalia.tr("notifications.no_path"))
    return
  end
  path = noctalia.expandPath(path)
  if not noctalia.fileExists(path) then
    noctalia.notifyError(noctalia.tr("notifications.import_failed"), noctalia.tr("notifications.file_not_found", { path = path }))
    return
  end
  finishImport(path, typeArg, false)
end

local function importFromText(text, typeArg)
  if type(text) ~= "string" or trim(text) == "" then
    noctalia.notifyError(noctalia.tr("notifications.import_failed"), noctalia.tr("notifications.no_paste"))
    return
  end
  -- Deliberately not logged: a pasted config carries private keys, PSKs and
  -- certificates, and the shell log is a world-readable file on disk.
  log(`importFromText received {#text} bytes`)
  local dir = noctalia.pluginDataDir()
  if dir == nil then
    noctalia.notifyError(noctalia.tr("notifications.import_failed"), noctalia.tr("notifications.no_data_dir"))
    return
  end
  local tmpPath = dir .. "/import-" .. tostring(math.floor(noctalia.nowMs())) .. ".tmp"
  local ok = noctalia.writeFile(tmpPath, text)
  if not ok then
    noctalia.notifyError(noctalia.tr("notifications.import_failed"), noctalia.tr("notifications.write_failed"))
    return
  end
  finishImport(tmpPath, typeArg, true)
end

-- ── trust evaluation / auto-connect decision ────────────────────────────

local function maybeAutoConnect()
  if not cfgBool("auto_connect_enabled", false) then
    return
  end
  local uuid = data.defaultVpnUuid
  if uuid == nil or uuid == "" then
    return
  end
  for _, row in ipairs(lastVpnRows) do
    if row.uuid == uuid then
      if row.active then
        return
      end
      connectUuid(uuid, true)
      return
    end
  end
  -- default VPN no longer exists
  data.defaultVpnUuid = ""
  saveData()
end

local function maybeAutoDisconnect()
  if not cfgBool("auto_disconnect_on_trusted", true) then
    return
  end
  local uuid = data.autoStartedUuid
  if uuid == nil or uuid == "" then
    return
  end
  disconnectUuid(uuid, true)
end

local function evaluateTrust(physicalRows)
  if #physicalRows == 0 then
    untrustedStreak = 0
    trustedStreak = 0
    return
  end
  local trustAllEthernet = cfgBool("trust_all_ethernet", true)
  local anyTrusted = false
  for _, row in ipairs(physicalRows) do
    if row.ctype == "802-3-ethernet" and trustAllEthernet then
      anyTrusted = true
    end
    if isTrusted(row.key) then
      anyTrusted = true
    end
  end

  local threshold = cfgInt("stable_checks", 1, 20, 3)
  if anyTrusted then
    trustedStreak += 1
    untrustedStreak = 0
    if trustedStreak >= threshold then
      maybeAutoDisconnect()
    end
  else
    untrustedStreak += 1
    trustedStreak = 0
    if untrustedStreak >= threshold then
      maybeAutoConnect()
    end
  end
end

-- ── full refresh: connections + network trust in one nmcli round trip ──────

refreshAll = function()
  if refreshInFlight then
    return
  end
  refreshInFlight = true

  run({ "nmcli", "-t", "-f", "NAME,TYPE,UUID,AUTOCONNECT,ACTIVE,DEVICE", "--escape", "no", "connection", "show" }, function(result)
    if result.exitCode ~= 0 then
      log("connection show failed: " .. firstLine(result.stderr))
      refreshInFlight = false
      return
    end

    local vpnRows, physicalRows = {}, {}
    for line in result.stdout:gmatch("[^\n]+") do
      local name, ctype, uuid, autoconnect, active, device = line:match("^(.*):([^:]*):([^:]*):([^:]*):([^:]*):([^:]*)$")
      if uuid ~= nil and uuid ~= "" then
        local row = {
          name = name,
          ctype = ctype,
          uuid = uuid,
          autoconnect = autoconnect == "yes",
          active = active == "yes",
          device = device,
        }
        if ctype == "vpn" or ctype == "wireguard" then
          table.insert(vpnRows, row)
        elseif row.active and (ctype == "802-11-wireless" or ctype == "802-3-ethernet") then
          table.insert(physicalRows, row)
        end
      end
    end

    mapAsync(vpnRows, function(row, done)
      if row.ctype == "wireguard" then
        row.protocol = "WireGuard"
        done(row)
      else
        run({ "nmcli", "-g", "vpn.service-type", "connection", "show", row.uuid }, function(r2)
          local svc = r2.exitCode == 0 and trim(r2.stdout) or ""
          row.protocol = friendlyProtocol(row.ctype, svc)
          done(row)
        end)
      end
    end, function(enrichedVpnRows)
      mapAsync(physicalRows, function(row, done)
        if row.ctype == "802-11-wireless" then
          run({ "nmcli", "-g", "802-11-wireless.ssid", "connection", "show", row.uuid }, function(r2)
            local ssid = r2.exitCode == 0 and trim(r2.stdout) or ""
            row.key = ssid ~= "" and ssid or row.name
            done(row)
          end)
        else
          row.key = row.name
          done(row)
        end
      end, function(enrichedPhysicalRows)
        lastVpnRows = enrichedVpnRows
        publishConnections()

        local currentNetworks = {}
        for _, row in ipairs(enrichedPhysicalRows) do
          table.insert(currentNetworks, {
            key = row.key,
            kind = row.ctype == "802-11-wireless" and "wifi" or "ethernet",
            trusted = isTrusted(row.key) or (row.ctype == "802-3-ethernet" and cfgBool("trust_all_ethernet", true)),
          })
        end
        noctalia.state.set("vpn.currentNetworks", currentNetworks)

        evaluateTrust(enrichedPhysicalRows)
        refreshInFlight = false
      end)
    end)
  end)
end

-- ── commands from panel / bar / shortcut ────────────────────────────────

-- ── connection details and editing ───────────────────────────────────────

-- NetworkManager UUIDs are hex and dashes. Validated before a UUID is ever
-- interpolated into the terminal fallback below, which is the one place this
-- plugin builds a shell string rather than an argv list.
local function isUuid(value)
  return type(value) == "string" and value:match("^[0-9a-fA-F%-]+$") ~= nil and #value >= 8
end

local DETAIL_FIELDS = "GENERAL.STATE,GENERAL.DEVICES,VPN.VPN-STATE,IP4.ADDRESS,IP4.GATEWAY,IP6.ADDRESS"

-- nmcli returns indexed keys for repeatable fields ("IP4.ADDRESS[1]"), so the
-- index is stripped before the label lookup.
local DETAIL_LABELS = {
  ["GENERAL.STATE"] = "state",
  ["GENERAL.DEVICES"] = "device",
  ["VPN.VPN-STATE"] = "vpn_state",
  ["IP4.ADDRESS"] = "ipv4",
  ["IP4.GATEWAY"] = "gateway",
  ["IP6.ADDRESS"] = "ipv6",
}

local function fetchDetails(uuid)
  if not isUuid(uuid) then
    return
  end
  run({ "nmcli", "-t", "-f", DETAIL_FIELDS, "connection", "show", "--active", uuid }, function(result)
    local rows = {}
    for _, line in ipairs(splitLines(result.stdout)) do
      local key, value = line:match("^([^:]+):(.*)$")
      if key ~= nil then
        local bare = key:gsub("%[%d+%]$", "")
        local labelKey = DETAIL_LABELS[bare]
        value = trim(value)
        if labelKey ~= nil and value ~= "" then
          table.insert(rows, { label = noctalia.tr(`panel.detail.{labelKey}`), value = value })
        end
      end
    end
    noctalia.state.set("vpn.details", { uuid = uuid, rows = rows })
  end)
end

-- nm-connection-editor is the graphical editor; where it is not installed, fall
-- back to nmtui-edit in a terminal. Neither is required for the plugin to work,
-- so a box with neither just gets told so.
local function editConnection(uuid)
  if not isUuid(uuid) then
    return
  end
  if noctalia.commandExists("nm-connection-editor") then
    run({ "nm-connection-editor", "--edit=" .. uuid })
  elseif noctalia.commandExists("nmtui-edit") then
    noctalia.runInTerminal("nmtui-edit " .. uuid)
  else
    noctalia.notifyError(noctalia.tr("title"), noctalia.tr("notifications.no_editor"))
  end
end

local function handleCommand(cmd)
  if type(cmd) ~= "table" then
    return
  end
  local op = cmd.op
  if op == "connect" then
    connectUuid(cmd.uuid, false)
  elseif op == "disconnect" then
    disconnectUuid(cmd.uuid, false)
  elseif op == "delete" then
    deleteUuid(cmd.uuid)
  elseif op == "setDefault" then
    data.defaultVpnUuid = cmd.uuid or ""
    saveData()
    publishTrust()
    publishConnections()
  elseif op == "trust" then
    local name = trim(cmd.name)
    if name ~= "" and not isTrusted(name) then
      table.insert(data.trustedNetworks, name)
      saveData()
      publishTrust()
      untrustedStreak = 0
    end
  elseif op == "untrust" then
    local name = trim(cmd.name)
    for i, n in ipairs(data.trustedNetworks) do
      if n == name then
        table.remove(data.trustedNetworks, i)
        break
      end
    end
    saveData()
    publishTrust()
  elseif op == "import" then
    importFromPath(cmd.path, cmd.importType)
  elseif op == "importText" then
    importFromText(cmd.text, cmd.importType)
  elseif op == "details" then
    fetchDetails(cmd.uuid)
  elseif op == "edit" then
    editConnection(cmd.uuid)
  elseif op == "refresh" then
    refreshAll()
  end
end

noctalia.state.watch("vpn.cmd", function(cmd)
  if cmd ~= nil then
    handleCommand(cmd)
    noctalia.state.set("vpn.cmd", nil)
  end
end)

function onIpc(event, payload)
  if event == "refresh" then
    refreshAll()
  elseif event == "connect" then
    connectUuid(payload, false)
  elseif event == "disconnect" then
    disconnectUuid(payload, false)
  elseif event == "status" then
    local names = {}
    for _, row in ipairs(lastVpnRows) do
      if row.active then
        table.insert(names, row.name)
      end
    end
    noctalia.notify(noctalia.tr("title"), #names > 0 and table.concat(names, ", ") or noctalia.tr("notifications.status_none"))
  elseif event == "list" then
    for _, row in ipairs(lastVpnRows) do
      log(`conn name={row.name} type={row.ctype} protocol={row.protocol} uuid={row.uuid} active={tostring(row.active)}`)
    end
    log(`trusted={table.concat(data.trustedNetworks, ",")} default={data.defaultVpnUuid} autoStarted={data.autoStartedUuid}`)
  elseif event == "import" then
    importFromPath(payload, nil)
  end
end

function onEnable()
  refreshAll()
end

function update()
  tickCount += 1
  local interval = cfgInt("poll_interval_seconds", 2, 60, 5)
  if tickCount % interval == 0 then
    refreshAll()
  end
end

loadData()
publishTrust()
publishAvailableProtocols()
noctalia.state.set("vpn.connections", {})
noctalia.state.set("vpn.status", { anyActive = false, activeNames = {} })
noctalia.state.set("vpn.currentNetworks", {})
noctalia.state.set("vpn.details", { uuid = "", rows = {} })
refreshAll()
