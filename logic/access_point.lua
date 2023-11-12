local META_CURR_PAGE = "ap_curr_p"
local META_SORT_TYPE = "ap_sort"
local META_FILTER_TYPE = "ap_fltr"
local META_CURR_SEARCH = "ap_curr_s"
local META_IGNORE_METADATA = "ap_usemd"

local fakeInvMap = {}

local SORT_NAME = 1
local SORT_MOD = 2
local SORT_COUNT = 3
local SORT_WEAR = 4
local sortMethodMap = {
  [SORT_NAME] = function(list) return logistica.sort_list_by(list, LOG_SORT_NAME_AZ) end,
  [SORT_MOD] = function(list) return logistica.sort_list_by(list, LOG_SORT_MOD_AZ) end,
  [SORT_COUNT] = function(list) return logistica.sort_list_by(list, LOG_SORT_STACK_SIZE_REV) end,
  [SORT_WEAR] = function(list) return logistica.sort_list_by(list, LOG_SORT_DURABILITY_FWD) end,
}

local FILTER_ALL = 1
local FILTER_NODES = 2
local FILTER_ITEMS = 3
local FILTER_TOOLS = 4
local FILTER_LIGHTS = 5

local filterMethodMap = {
  [FILTER_ALL] = function(list) return list end,
  [FILTER_NODES] = function(list) return logistica.filter_list_by(list, LOG_FILTER_NODE) end,
  [FILTER_ITEMS] = function(list) return logistica.filter_list_by(list, LOG_FILTER_CRAFTITEM) end,
  [FILTER_TOOLS] = function(list) return logistica.filter_list_by(list, LOG_FILTER_TOOL) end,
  [FILTER_LIGHTS] = function(list) return logistica.filter_list_by(list, LOG_FILTER_LIGHT) end,
}

local h2p = minetest.get_position_from_hash
local pth = minetest.hash_node_position
local get_meta = minetest.get_meta

local function get_curr_sort_method_int(meta)
  local curr = meta:get_int(META_SORT_TYPE)
  if curr <= 0 or curr >= 5 then return 1 else return curr end
end

local function set_curr_sort_method_int(meta, methodIndex)
  meta:set_int(META_SORT_TYPE, methodIndex)
end

local function get_curr_filter_method_int(meta)
  local curr = meta:get_int(META_FILTER_TYPE)
  if curr <= 0 or curr >= 6 then return 1 else return curr end
end

local function set_curr_filter_method_int(meta, methodIndex)
  meta:set_int(META_FILTER_TYPE, methodIndex)
end

local function add_list_to_itemmap(itemMap, list, useMetadata)
  for _, stack in ipairs(list) do
    if not stack:is_empty() then
      local stackName = stack:get_name()
      if useMetadata then stackName = stack:to_string() end
      if itemMap[stackName] == nil then itemMap[stackName] = 0 end
      itemMap[stackName] = itemMap[stackName] + stack:get_count()
    end
  end
end

local function build_stack_list(pos)
  local network = logistica.get_network_or_nil(pos)
  if not network then return {stackList = {}, stackListSize = 0} end
  local useMetadata = logistica.access_point_is_set_to_use_metadata(pos)
  local meta = get_meta(pos)

  local itemMap = {}
  -- we scan all supply chests and mass storage and item storage
  for hash, _ in pairs(network.suppliers) do
    local mPos = logistica.load_position(h2p(hash))
    local list = get_meta(mPos):get_inventory():get_list("main") or {}
    add_list_to_itemmap(itemMap, list, useMetadata)
  end
  for hash, _ in pairs(network.mass_storage) do
    local mPos = logistica.load_position(h2p(hash))
    local list = get_meta(mPos):get_inventory():get_list("storage") or {}
    add_list_to_itemmap(itemMap, list, useMetadata)
  end
  for hash, _ in pairs(network.item_storage) do
    local mPos = logistica.load_position(h2p(hash))
    local list = get_meta(mPos):get_inventory():get_list("main") or {}
    add_list_to_itemmap(itemMap, list, useMetadata)
  end
  local itemList = {}
  local listSize = 0
  for item, count in pairs(itemMap) do
    local stack = ItemStack(item)
    stack:set_count(count)
    listSize = listSize + 1
    itemList[listSize] = stack
  end
  local filtered = filterMethodMap[get_curr_filter_method_int(meta)](itemList)
  local sorted = sortMethodMap[get_curr_sort_method_int(meta)](filtered)
  return {
    stackList = sorted,
    stackListSize = listSize,
  }
end


--------------------------------
-- public functions
--------------------------------

function logistica.access_point_on_player_close(playerName)
  fakeInvMap[playerName] = nil
end

function logistica.update_fake_inv(pos, listName, listSize, playerName)
  local meta = get_meta(pos)
  local inv = meta:get_inventory()
  local pageInfo = logistica.access_point_get_current_page_info(pos, playerName, listSize, meta)
  if pageInfo.max == 0 then inv:set_list(listName, {}) ; return end
  local startingPos = (pageInfo.curr - 1) * listSize + 1
  local fullList = fakeInvMap[playerName].stackList
  if not fullList then return end
  local fakeInvList = {}
  for i = startingPos, startingPos + listSize do
    fakeInvList[i - startingPos + 1] = fullList[i] or ItemStack("")
  end
  inv:set_list(listName, fakeInvList)
end

-- returns a table representing pages: {curr = #, max = #}
function logistica.access_point_get_current_page_info(pos, playerName, listSize, optMeta)
  if not fakeInvMap[playerName] then return {curr = 0, max = 0} end
  local meta = optMeta or get_meta(pos)
  local storedPage = meta:get_int(META_CURR_PAGE)
  if storedPage <= 0 then storedPage = 1 end
  local fakeInv = fakeInvMap[playerName]
  local maxPages = math.ceil(fakeInv.stackListSize / listSize)
  if storedPage > maxPages then
    storedPage = maxPages
    meta:set_int(META_CURR_PAGE, storedPage)
  end
  return {curr = storedPage, max = maxPages}
end

function logistica.access_point_is_set_to_use_metadata(pos)
  local meta = get_meta(pos)
  return meta:get_int(META_IGNORE_METADATA) == 0
end

-- toggles whether to use metadata and returns the new state
function logistica.access_point_toggle_use_metadata(pos)
  local meta = get_meta(pos)
  local curr = meta:get_int(META_IGNORE_METADATA)
  local new = (curr + 1) % 2
  meta:set_int(META_IGNORE_METADATA, new)
  return new == 0
end

-- returns true if page was changed, false if it wasn't
function logistica.access_point_change_page(pos, op, playerName, listSize)
  local meta = get_meta(pos)
  local currInfo = logistica.access_point_get_current_page_info(pos, playerName, listSize, meta)
  if currInfo.max == 0 then return false end
  local newPage = currInfo.curr
  if op == 1 then newPage = newPage + 1
  elseif op > 1 then newPage = currInfo.max
  elseif op == -1 then newPage = newPage - 1
  elseif op < -1 then newPage = 1 end
  newPage = logistica.clamp(newPage, 1, currInfo.max)
  if currInfo.curr == newPage then return false end
  meta:set_int(META_CURR_PAGE, newPage)
  return true
end

function logistica.access_point_get_filter_highlight_images(meta, highlightImg, blankImg)
  local method = get_curr_filter_method_int(meta)
  return {
    all = (method == FILTER_ALL and highlightImg) or blankImg,
    node = (method == FILTER_NODES and highlightImg) or blankImg,
    craftitem = (method == FILTER_ITEMS and highlightImg) or blankImg,
    tools = (method == FILTER_TOOLS and highlightImg) or blankImg,
    lights = (method == FILTER_LIGHTS and highlightImg) or blankImg,
  }
end

function logistica.access_point_get_sort_highlight_images(meta, highlightImg, blankImg)
  local method = get_curr_sort_method_int(meta)
  return {
    name = (method == SORT_NAME and highlightImg) or blankImg,
    mod = (method == SORT_MOD and highlightImg) or blankImg,
    count = (method == SORT_COUNT and highlightImg) or blankImg,
    wear = (method == SORT_WEAR and highlightImg) or blankImg,
  }
end

function logistica.access_point_refresh_fake_inv(pos, listName, listSize, playerName)
  local listInfo = build_stack_list(pos)
  fakeInvMap[playerName] = listInfo
  logistica.update_fake_inv(pos, listName, listSize, playerName)
end

function logistica.access_point_set_filter_method(pos, playerName, method)
  set_curr_filter_method_int(get_meta(pos), method)
end

function logistica.access_point_set_sort_method(pos, playerName, method)
  set_curr_sort_method_int(get_meta(pos), method)
end