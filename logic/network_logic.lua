local networks = {}
local HARD_NETWORK_NODE_LIMIT = 1000 -- A network cannot consist of more than this many nodes
local STATUS_OK = 0
local CREATE_NETWORK_STATUS_FAIL_OTHER_NETWORK = -1
local CREATE_NETWORK_STATUS_TOO_MANY_NODES = -2

-- logistica.networks = networks

local p2h = minetest.hash_node_position
local h2p = minetest.get_position_from_hash

local adjecent = {
  vector.new( 1,  0,  0),
  vector.new( 0,  1,  0),
  vector.new( 0,  0,  1),
  vector.new(-1,  0,  0),
  vector.new( 0, -1,  0),
  vector.new( 0,  0, -1),
}

local function has_machine(network, id)
  if not network then return false end
  if network.demanders[id] or network.suppliers[id] or network.mass_storage[id] or network.item_storage[id]
  then
    return true
  else
    return false
  end
end

function logistica.get_network_by_id_or_nil(networkId)
  return networks[networkId]
end

function logistica.get_network_or_nil(pos)
  local hash = p2h(pos)
  for nHash, network in pairs(networks) do
    if hash == nHash then return network end
    if network.cables[hash] then return network end
    if has_machine(network, hash) then return network end
  end
  return nil
end

function logistica.get_network_name_or_nil(pos)
  local network = logistica.get_network_or_nil(pos)
  if not network then return nil else return network.name end
end

function logistica.rename_network(networkId, newName)
  local network = networks[networkId]
  if not network then return false end
  network.name = newName
  return true
end

function logistica.get_network_id_or_nil(pos)
  local network = logistica.get_network_or_nil(pos)
  if not network then return nil else return network.controller end
end

local function notify_connected(pos, node, networkId)
  local def = minetest.registered_nodes[node.name]
  if def and def.logistica and def.logistica.on_connect_to_network then
    def.logistica.on_connect_to_network(pos, networkId)
  end
end

----------------------------------------------------------------
-- Network operation functions
----------------------------------------------------------------

local function clear_network(networkName)
  local network = networks[networkName]
  if not network then return false end
  networks[networkName] = nil
end

local function break_logistica_node(pos)
  local node = minetest.get_node(pos)
  logistica.swap_node(pos, node.name .. "_disabled")
end

-- returns a naturally numbered list of networks on adjecent nodes
local function find_adjecent_networks(pos)
  local connectedNetworks = {}
  for _, adj in pairs(adjecent) do
    local otherPos = vector.add(pos, adj)
    local otherNetwork = logistica.get_network_id_or_nil(otherPos)
    if otherNetwork then
      connectedNetworks[otherNetwork] = true
    end
  end
  local retNetworks = {}
  for k,_ in pairs(connectedNetworks) do
    table.insert(retNetworks, networks[k])
  end
  return retNetworks
end

local function recursive_scan_for_nodes_for_controller(network, positionHashes, numScanned)
  if not numScanned then numScanned = 0 end

  if numScanned > HARD_NETWORK_NODE_LIMIT then
    return CREATE_NETWORK_STATUS_TOO_MANY_NODES
  end

  local connections = {}
  local newToScan = 0
  for posHash, _ in pairs(positionHashes) do
    local pos = h2p(posHash)
    numScanned = numScanned + 1
    logistica.load_position(pos)
    local tiers = logistica.get_item_tiers(minetest.get_node(pos).name)
    local isAllTier = tiers[logistica.TIER_ALL] == true
    for _, offset in pairs(adjecent) do
      local otherPos = vector.add(pos, offset)
      logistica.load_position(otherPos)
      local otherNode = minetest.get_node(otherPos)
      local otherHash = p2h(otherPos)
      if network.controller ~= otherHash
          and not has_machine(network, otherHash)
          and network.cables[otherHash] == nil then
        local tiersMatch = isAllTier
        if tiersMatch ~= true then
          local otherTiers = logistica.get_item_tiers(minetest.get_node(otherPos).name)
          tiersMatch = logistica.do_tiers_match(tiers, otherTiers)
        end
        if tiersMatch then
          local existingNetwork = logistica.get_network_id_or_nil(otherPos)
          if existingNetwork ~= nil and existingNetwork ~= network then
            return CREATE_NETWORK_STATUS_FAIL_OTHER_NETWORK
          end
          local valid = false
          if logistica.is_cable(otherNode.name) then
            network.cables[otherHash] = true
            connections[otherHash] = true
            valid = true
          elseif logistica.is_demander(otherNode.name) then
            network.demanders[otherHash] = true
            valid = true
          elseif logistica.is_supplier(otherNode.name) then
            network.suppliers[otherHash] = true
            valid = true
          elseif logistica.is_mass_storage(otherNode.name) then
            network.mass_storage[otherHash] = true
            valid = true
          elseif logistica.is_item_storage(otherNode.name) then
            network.item_storage[otherHash] = true
            valid = true
          end
          if valid then
            newToScan = newToScan + 1
            notify_connected(otherPos, otherNode, network.controller)
          end
        end -- end if tiersMatch
      end -- end of general checks
    end -- end inner for loop
  end -- end outer for loop

  -- We have nested loops so we can do tail recursion
  if newToScan <= 0 then return STATUS_OK
  else return recursive_scan_for_nodes_for_controller(network, connections, numScanned) end
end

local function create_network(controllerPosition, oldNetworkName)
  local node = minetest.get_node(controllerPosition)
  if not node.name:find("_controller") or not node.name:find("logistica:") then return false end
  local meta = minetest.get_meta(controllerPosition)
  local controllerHash = p2h(controllerPosition)
  local network = {}
  local nameFromMeta = meta:get_string("name")
  if nameFromMeta == "" then nameFromMeta = nil end
  local networkName = oldNetworkName or nameFromMeta or logistica.get_network_name_for(controllerPosition)
  networks[controllerHash] = network
  meta:set_string("infotext", "Controller of Network: "..networkName)
  network.controller = controllerHash
  network.name = networkName
  network.cables = {}
  network.demanders = {}
  network.suppliers = {}
  network.mass_storage = {}
  network.item_storage = {}
  network.storage_cache = {}
  network.supplier_cache = {}
  local startPos = {}
  startPos[controllerHash] = true
  local status = recursive_scan_for_nodes_for_controller(network, startPos)
  local errorMsg = nil
  if status == CREATE_NETWORK_STATUS_FAIL_OTHER_NETWORK then
    errorMsg = "Cannot create network: Would overlap with another network!"
    break_logistica_node(controllerPosition)
  elseif status == CREATE_NETWORK_STATUS_TOO_MANY_NODES then
    errorMsg = "Controller max nodes limit of "..HARD_NETWORK_NODE_LIMIT.." nodes per network exceeded!"
  elseif status == STATUS_OK then
    -- controller scan skips updating storage cache, do so now
    logistica.update_mass_storage_cache(network)
    logistica.update_supplier_cache(network)
  end
  if errorMsg ~= nil then
    networks[controllerHash] = nil
    meta:set_string("infotext", "ERROR: "..errorMsg)
  end
end

----------------------------------------------------------------
-- worker functions for cable/machine/controllers
----------------------------------------------------------------

local function rescan_network(networkId)
  local network = networks[networkId]
  if not network then return false end
  if not network.controller then return false end
  local conHash = network.controller
  local controllerPosition = h2p(conHash)
  local oldNetworkName = network.name
  clear_network(networkId)
  create_network(controllerPosition, oldNetworkName)
end

local function find_cable_connections(pos, node)
  local connections = {}
  for _, offset in pairs(adjecent) do
    local otherPos = vector.add(pos, offset)
    local otherNode = minetest.get_node_or_nil(otherPos)
    if otherNode then
      if otherNode.name == node.name then
        table.insert(connections, otherPos)
      elseif minetest.get_item_group(otherNode, logistica.GROUP_ALL) > 0 then
        table.insert(connections, otherPos)
      else -- check if adjecent node is a machine of same tier
        local nodeTiers = logistica.get_item_tiers(node.name)
        local otherTiers = logistica.get_item_tiers(otherNode.name)
        if logistica.do_tiers_match(nodeTiers, otherTiers) then
          table.insert(connections, otherPos)
        end
      end
    end
  end
  return connections
end

local function try_to_add_network(pos)
  create_network(pos)
end

local function try_to_add_to_network(pos, ops)
  local connectedNetworks = find_adjecent_networks(pos)
  if #connectedNetworks <= 0 then return STATUS_OK end -- nothing to connect to
  if #connectedNetworks >= 2 then
    break_logistica_node(pos) -- swap out storage node for disabled one 
    minetest.get_meta(pos):set_string("infotext", "ERROR: cannot connect to multiple networks!")
  end
  -- else, we have 1 network, add us to it!
  ops.get_list(connectedNetworks[1])[p2h(pos)] = true
  ops.update_cache_node_added(connectedNetworks[1])
end

local function remove_from_network(pos, ops)
  local hash = p2h(pos)
  local network = logistica.get_network_or_nil(pos)
  if not network then return end
  ops.get_list(network)[hash] = nil
  ops.update_cache_node_removed(network)
end

local function MASS_STORAGE_OPS(pos) return {
  get_list = function(network) return network.mass_storage end,
  update_cache_node_added = function(_) logistica.update_mass_storage_on_item_added(pos) end,
  update_cache_node_removed = function(network) logistica.update_mass_storage_cache(network) end,
} end
local function try_to_add_mass_storage_to_network(pos)
  try_to_add_to_network(pos, MASS_STORAGE_OPS(pos))
end

local function remove_mass_storage_from_network(pos)
  remove_from_network(pos, MASS_STORAGE_OPS(pos))
end

local DEMANDER_OPS = {
  get_list = function(network) return network.demanders end,
  update_cache_node_added = function(_) end,
  update_cache_node_removed = function(_) end,
}
local function try_to_add_demander_to_network(pos)
  try_to_add_to_network(pos,DEMANDER_OPS)
end
local function remove_demander_from_network(pos)
  remove_from_network(pos, DEMANDER_OPS)
end

local function SUPPLIER_OPS(pos) return {
  get_list = function(network) return network.suppliers end,
  update_cache_node_added = function(_) logistica.update_supplier_on_item_added(pos) end,
  update_cache_node_removed = function(network) logistica.update_supplier_cache(network) end,
} end
local function try_to_add_supplier_to_network(pos)
  try_to_add_to_network(pos, SUPPLIER_OPS(pos))
end
local function remove_supplier_from_network(pos)
  remove_from_network(pos, SUPPLIER_OPS(pos))
end

----------------------------------------------------------------
-- global namespaced functions
----------------------------------------------------------------

function logistica.on_cable_change(pos, oldNode)
  local node = oldNode or minetest.get_node(pos)
  local meta = minetest.get_meta(pos)
  local placed = (oldNode == nil) -- if oldNode is nil, we placed it

  local connections = find_cable_connections(pos, node)
  if not connections or #connections < 1 then return end -- nothing to update
  local networkEnd = #connections == 1

  if networkEnd then
    if not placed then -- removed a network end
      local network = logistica.get_network_or_nil(pos)
      if network then network.cables[p2h(pos)] = nil end
    else
      local otherNetwork = logistica.get_network_or_nil(connections[1])
      if otherNetwork then
        otherNetwork.cables[p2h(pos)] = true
      end
    end
    return -- was a network end, no need to do anything else
  end

  -- We have more than 1 connected nodes - either cables or machines, something needs recalculating
  local connectedNetworks = {}
  for _, connectedPos in pairs(connections) do
    local otherNetwork = logistica.get_network_id_or_nil(connectedPos)
    if otherNetwork then
      connectedNetworks[otherNetwork] = true
    end
  end
  local firstNetwork = nil
  local numNetworks = 0
  for k,_ in pairs(connectedNetworks) do
    numNetworks = numNetworks + 1
    if firstNetwork == nil then firstNetwork = k end
  end
  if numNetworks <= 0 then return end -- still nothing to update
  if numNetworks == 1 then
    rescan_network(firstNetwork)
  else
    -- two or more connected networks (should only happen on place)
    -- this cable can't work here, break it, and nothing to update
    break_logistica_node(pos)
    meta:set_string("infotext", "ERROR: cannot connect to multiple networks!")
  end
end

function logistica.on_controller_change(pos, oldNode)
  local hashPos = p2h(pos)
  local placed = (oldNode == nil) -- if oldNode is nil, we placed a new one
  if placed == true then
    try_to_add_network(pos)
  else
    clear_network(hashPos)
  end
end

function logistica.on_storage_change(pos, oldNode)
  local placed = (oldNode == nil) -- if oldNode is nil, we placed a new one
  if placed == true then
    try_to_add_mass_storage_to_network(pos)
  else
    remove_mass_storage_from_network(pos)
  end
end

function logistica.on_demander_change(pos, oldNode)
  local placed = (oldNode == nil) -- if oldNode is nil, we placed a new one
  if placed == true then
    try_to_add_demander_to_network(pos)
  else
    remove_demander_from_network(pos)
  end
end

function logistica.on_supplier_change(pos, oldNode)
  local placed = (oldNode == nil) -- if oldNode is nil, we placed a new one
  if placed == true then
    try_to_add_supplier_to_network(pos)
  else
    remove_supplier_from_network(pos)
  end
end
