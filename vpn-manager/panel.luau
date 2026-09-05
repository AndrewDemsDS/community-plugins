--!nonstrict
-- VPN Manager panel: connection list (connect/disconnect/star/delete),
-- import form (file path or pasted config), and trusted-network management.

local connections = {}
local trustedNetworks = {}
local currentNetworks = {}
local defaultVpnUuid = ""
local availableProtocols = {}

local pendingDeleteVpn = nil

local showAdd = false
local IMPORT_TYPES = {
  { label = "Auto-detect", value = "" },
  { label = "OpenVPN (.ovpn)", value = "openvpn" },
  { label = "WireGuard (.conf)", value = "wireguard" },
  { label = "Cisco AnyConnect (openconnect)", value = "openconnect" },
  { label = "Cisco legacy VPN (vpnc)", value = "vpnc" },
}
local importTypeIndex = 0
local pathDraft = ""
local pathKey = 0
local pasteDraft = ""
local pasteKey = 0

local showTrust = false
local trustDraft = ""
local trustKey = 0

local function importTypeLabels()
  local labels = {}
  for _, t in ipairs(IMPORT_TYPES) do
    table.insert(labels, t.label)
  end
  return labels
end

local function statusDot(active, busy)
  return ui.box({
    width = 8,
    height = 8,
    radius = 4,
    fill = if busy then "on_surface_variant" elseif active then "primary" else "outline",
  })
end

local function protocolBadge(available)
  return ui.glyph({
    name = if available then "check" else "x",
    size = 12,
    color = if available then "primary" else "on_surface_variant",
  })
end

local function connectionRow(row)
  local uuid = row.uuid
  local deleting = pendingDeleteVpn == uuid

  local trailing
  if deleting then
    trailing = ui.row({ gap = 4, align = "center" }, {
      ui.button({
        glyph = "check",
        variant = "destructive",
        controlSize = "sm",
        onClick = function()
          pendingDeleteVpn = nil
          noctalia.state.set("vpn.cmd", { op = "delete", uuid = uuid })
        end,
      }),
      ui.button({
        glyph = "x",
        variant = "ghost",
        controlSize = "sm",
        onClick = function()
          pendingDeleteVpn = nil
          render()
        end,
      }),
    })
  else
    trailing = ui.row({ gap = 2, align = "center" }, {
      ui.button({
        glyph = if row.isDefault then "star-filled" else "star",
        variant = "ghost",
        controlSize = "sm",
        tooltip = "Use as auto-connect default",
        onClick = function()
          noctalia.state.set("vpn.cmd", { op = "setDefault", uuid = if row.isDefault then "" else uuid })
        end,
      }),
      ui.toggle({
        checked = row.active,
        enabled = not row.busy,
        onChange = function(_value)
          if row.active then
            noctalia.state.set("vpn.cmd", { op = "disconnect", uuid = uuid })
          else
            noctalia.state.set("vpn.cmd", { op = "connect", uuid = uuid })
          end
        end,
      }),
      ui.button({
        glyph = "trash",
        variant = "ghost",
        controlSize = "sm",
        onClick = function()
          pendingDeleteVpn = uuid
          render()
        end,
      }),
    })
  end

  return ui.row({
    key = "vpn-" .. uuid,
    gap = 8,
    align = "center",
    paddingV = 6,
    paddingH = 8,
    fill = "surface_variant/0.35",
    radius = 8,
  }, {
    statusDot(row.active, row.busy),
    ui.column({ flexGrow = 1, gap = 1 }, {
      ui.label({ text = row.name, fontWeight = "bold", fontSize = 13 }),
      ui.label({ text = row.protocol, color = "on_surface_variant", fontSize = 10 }),
    }),
    trailing,
  })
end

local function connectionsSection()
  local rows = {}
  if #connections == 0 then
    table.insert(rows, ui.label({
      text = "No VPN connections yet. Import one below, or create one with nmtui and it will show up here.",
      color = "on_surface_variant",
      fontSize = 12,
      maxLines = 3,
    }))
  else
    for _, row in ipairs(connections) do
      table.insert(rows, connectionRow(row))
    end
  end
  return ui.column({ gap = 6 }, rows)
end

local function addSection()
  if not showAdd then
    return ui.button({
      text = "Add VPN",
      glyph = "plus",
      variant = "outline",
      onClick = function()
        showAdd = true
        render()
      end,
    })
  end

  local protoNote = {}
  for _, t in ipairs(IMPORT_TYPES) do
    if t.value ~= "" then
      table.insert(protoNote, ui.row({ gap = 4, align = "center" }, {
        protocolBadge(availableProtocols[t.value] == true),
        ui.label({ text = t.label, fontSize = 10, color = "on_surface_variant" }),
      }))
    end
  end
  -- no wrap support on ui.row: lay badges out two per row instead of one long strip
  local protoRows = {}
  for i = 1, #protoNote, 2 do
    local rowItems = { protoNote[i] }
    if protoNote[i + 1] ~= nil then
      table.insert(rowItems, protoNote[i + 1])
    end
    table.insert(protoRows, ui.row({ gap = 14 }, rowItems))
  end

  return ui.column({ gap = 8, padding = 8, fill = "surface_variant/0.25", radius = 8 }, {
    ui.row({ align = "center", justify = "space_between" }, {
      ui.label({ text = "Add VPN", fontWeight = "bold", fontSize = 13, flexGrow = 1 }),
      ui.button({
        glyph = "x",
        variant = "ghost",
        controlSize = "sm",
        onClick = function()
          showAdd = false
          render()
        end,
      }),
    }),
    ui.column({ gap = 4 }, protoRows),
    ui.label({ text = "Protocol", fontSize = 11, color = "on_surface_variant" }),
    ui.select({
      key = "import-type",
      options = importTypeLabels(),
      selectedIndex = importTypeIndex,
      onChange = function(index, _text)
        importTypeIndex = tonumber(index) or 0
        render()
      end,
    }),
    ui.label({ text = "Import from file", fontSize = 11, color = "on_surface_variant" }),
    ui.row({ gap = 6, align = "center" }, {
      ui.input({
        key = "path-" .. pathKey,
        value = pathDraft,
        placeholder = "~/Downloads/client.ovpn",
        flexGrow = 1,
        onChange = function(value)
          pathDraft = value
        end,
        onSubmit = "onImportPath",
      }),
      ui.button({ text = "Import", onClick = "onImportPath" }),
    }),
    ui.label({ text = "or paste a config", fontSize = 11, color = "on_surface_variant" }),
    ui.input({
      key = "paste-" .. pasteKey,
      value = pasteDraft,
      placeholder = "[Interface] / [Peer] for WireGuard, or full .ovpn contents",
      multiline = true,
      height = 90,
      onChange = function(value)
        pasteDraft = value
      end,
    }),
    ui.button({ text = "Import Pasted Config", variant = "primary", onClick = "onImportPaste" }),
    ui.label({
      text = "PPTP, L2TP/IPsec and IKEv2 usually need fields typed in rather than a file - create those with nmtui or nm-connection-editor and they'll appear above automatically.",
      fontSize = 10,
      color = "on_surface_variant",
      maxLines = 4,
    }),
  })
end

local function trustSection()
  local header = ui.row({ align = "center", justify = "space_between" }, {
    ui.label({ text = "Trusted networks", fontWeight = "bold", fontSize = 13, flexGrow = 1 }),
    ui.button({
      glyph = if showTrust then "chevron-up" else "chevron-down",
      variant = "ghost",
      controlSize = "sm",
      onClick = function()
        showTrust = not showTrust
        render()
      end,
    }),
  })

  if not showTrust then
    return header
  end

  local rows = { header }
  if #trustedNetworks == 0 then
    table.insert(rows, ui.label({
      text = "None yet. VPN auto-connect (if enabled in Settings) treats every network as untrusted until you add one.",
      color = "on_surface_variant",
      fontSize = 11,
      maxLines = 3,
    }))
  else
    for _, name in ipairs(trustedNetworks) do
      table.insert(rows, ui.row({
        key = "trust-" .. name,
        gap = 6,
        align = "center",
        paddingV = 3,
        paddingH = 6,
        fill = "surface_variant/0.25",
        radius = 6,
      }, {
        ui.glyph({ name = "wifi", size = 12, color = "on_surface_variant" }),
        ui.label({ text = name, fontSize = 12, flexGrow = 1 }),
        ui.button({
          glyph = "trash",
          variant = "ghost",
          controlSize = "sm",
          onClick = function()
            noctalia.state.set("vpn.cmd", { op = "untrust", name = name })
          end,
        }),
      }))
    end
  end

  local untrustedCurrent = {}
  for _, net in ipairs(currentNetworks) do
    if not net.trusted then
      table.insert(untrustedCurrent, net)
    end
  end
  for _, net in ipairs(untrustedCurrent) do
    table.insert(rows, ui.button({
      key = "add-current-" .. net.key,
      text = "+ Trust '" .. net.key .. "'",
      variant = "outline",
      controlSize = "sm",
      onClick = function()
        noctalia.state.set("vpn.cmd", { op = "trust", name = net.key })
      end,
    }))
  end

  table.insert(rows, ui.row({ gap = 6, align = "center" }, {
    ui.input({
      key = "trust-add-" .. trustKey,
      value = trustDraft,
      placeholder = "SSID or Ethernet connection name",
      flexGrow = 1,
      onChange = function(value)
        trustDraft = value
      end,
      onSubmit = "onTrustAdd",
    }),
    ui.button({ glyph = "plus", onClick = "onTrustAdd" }),
  }))

  return ui.column({ gap = 6 }, rows)
end

function render()
  panel.render(ui.column({ flexGrow = 1, gap = 10, padding = 10 }, {
    ui.row({ align = "center", justify = "space_between" }, {
      ui.label({ text = "VPN", fontSize = 16, fontWeight = "bold", flexGrow = 1 }),
      ui.button({
        glyph = "refresh",
        variant = "ghost",
        controlSize = "sm",
        onClick = function()
          noctalia.state.set("vpn.cmd", { op = "refresh" })
        end,
      }),
      ui.button({
        glyph = "settings",
        variant = "ghost",
        controlSize = "sm",
        tooltip = "Plugin settings",
        onClick = function()
          noctalia.openSettings()
        end,
      }),
      ui.button({
        glyph = "x",
        variant = "ghost",
        controlSize = "sm",
        onClick = function()
          panel.close()
        end,
      }),
    }),
    ui.scroll({ flexGrow = 1, gap = 12 }, {
      connectionsSection(),
      addSection(),
      ui.separator({}),
      trustSection(),
    }),
  }))
end

function onImportPath()
  local typeValue = IMPORT_TYPES[importTypeIndex + 1].value
  noctalia.state.set("vpn.cmd", { op = "import", path = pathDraft, importType = typeValue ~= "" and typeValue or nil })
  pathDraft = ""
  pathKey += 1
  render()
end

function onImportPaste()
  local typeValue = IMPORT_TYPES[importTypeIndex + 1].value
  noctalia.state.set("vpn.cmd", { op = "importText", text = pasteDraft, importType = typeValue ~= "" and typeValue or nil })
  pasteDraft = ""
  pasteKey += 1
  render()
end

function onTrustAdd()
  local name = noctalia.string.trim(trustDraft)
  if name ~= "" then
    noctalia.state.set("vpn.cmd", { op = "trust", name = name })
  end
  trustDraft = ""
  trustKey += 1
  render()
end

function onOpen(_context)
  pendingDeleteVpn = nil
  showAdd = false
  connections = noctalia.state.get("vpn.connections") or {}
  trustedNetworks = noctalia.state.get("vpn.trustedNetworks") or {}
  currentNetworks = noctalia.state.get("vpn.currentNetworks") or {}
  defaultVpnUuid = noctalia.state.get("vpn.defaultVpnUuid") or ""
  availableProtocols = noctalia.state.get("vpn.availableProtocols") or {}
  noctalia.state.set("vpn.cmd", { op = "refresh" })
  render()
end

noctalia.state.watch("vpn.connections", function(value)
  connections = type(value) == "table" and value or {}
  render()
end)

noctalia.state.watch("vpn.trustedNetworks", function(value)
  trustedNetworks = type(value) == "table" and value or {}
  render()
end)

noctalia.state.watch("vpn.currentNetworks", function(value)
  currentNetworks = type(value) == "table" and value or {}
  render()
end)

noctalia.state.watch("vpn.defaultVpnUuid", function(value)
  defaultVpnUuid = type(value) == "string" and value or ""
end)

noctalia.state.watch("vpn.availableProtocols", function(value)
  availableProtocols = type(value) == "table" and value or {}
end)
