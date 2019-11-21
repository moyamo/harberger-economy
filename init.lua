harberger_economy = {}

-- Load config

-- NOTE minetest.settings.get will return null if the setting is not set by the
-- user (and not the default value). Thus default values must be duplicated
-- here. Take care to keep them in sync.

local function settings_get_int(s, default)
  -- unfortunately settings:get always gets a string (or nil) so we have to convert to number
  local t = minetest.settings:get(s)
  if t then
    return tonumber(t)
  else
    return default
  end
end

harberger_economy.config = {
  starting_income = settings_get_int('harberger_economy.starting_income', 10000),
  update_delay = settings_get_int('harberger_economy.update_delay', 1),
  price_index = settings_get_int('harberger_economy.price_index', 10000),
}

local TIME_SPEED = 72 -- This is a default constant in minetest, but I can't
                      -- seem to find it anywhere, so I'm going to hard code it.

function harberger_economy.log(logtype, logmessage)
  minetest.log(logtype, 'harberger_economy: ' .. logmessage)
end

-- Rounds number stochastic ally
function harberger_economy.round(n)
  local p = math.random()
  local w = math.floor(n)
  local f = n - w
  if p < f then
    return w + 1
  else
    return w
  end
end

-- BEGIN Private storage api

harberger_economy.storage = minetest.get_mod_storage()

local default_data = {
  offers = {
  },
  reserve_offers = {
    -- key is username to a table with
    -- key as item name to a table
    -- {amount = 103, ordering = {nil or list of locations for the prefered ordering to take items }}
  },
  balances = {
  },
  transactions = {
  },
  initialized_players = {
    -- contains key-value pair of player and bool, is nil if not initialized and true if initialized
  }
}
local current_schema = '4'
local cached_storage = nil
local batch_storage = 0
function harberger_economy.get_storage()
  if batch_storage == 0 then
    local data_string = harberger_economy.storage:get('data')
    if not data_string then
      cached_storage = default_data
    else
      data_with_schema = minetest.deserialize(data_string)
      if data_with_schema.schema ~= current_schema then
        cached_storage = default_data
      else
        cached_storage = data_with_schema.data
      end
    end
  end
  return cached_storage
end

function harberger_economy.set_storage(data)
  cached_storage = data
  if batch_storage == 0 then
    local data_with_schema = {
      schema = current_schema,
      data = data,
    }
    local data_string = minetest.serialize(data_with_schema)
    harberger_economy.storage:set_string('data', data_string)
  end
end

function harberger_economy.with_storage(func)
  local storage = harberger_economy.get_storage()
  batch_storage = batch_storage + 1
  local return_value = func(storage)
  batch_storage = batch_storage - 1
  harberger_economy.set_storage(storage)
  return return_value
end

function harberger_economy.batch_storage(func)
  return harberger_economy.with_storage(
    function (storage)
      return func()
    end
  )
end

-- END private storage api

-- BEGIN public storage api

function harberger_economy.initialize_player(player_name)
  return harberger_economy.with_storage(function (storage)
      if storage.initialized_players[player_name] then
        harberger_economy.log('warning', 'Player ' .. player_name .. ' is already initialized, ignoring.' )
      else
        harberger_economy.log('action', 'Initializing ' .. player_name)
        storage.offers[player_name] = {}
        storage.reserve_offers[player_name] = {}
        storage.initialized_players[player_name] = true
        storage.balances[player_name] = 0
        storage.transactions[player_name] = {}
      end
  end)
end

function harberger_economy.is_player_initialized(player_name)
  return harberger_economy.with_storage(function (storage)
      return not not storage.initialized_players[player_name]
  end)
end

function harberger_economy.get_reserve_offer(player_name, item_name)
  return harberger_economy.with_storage(function (storage)
      return storage.reserve_offers[player_name][item_name]
  end)
end

function harberger_economy.set_reserve_price(player_name, item_name, price)
  return harberger_economy.with_storage(function (storage)
      price = harberger_economy.round(price)
      local old_reserve = storage.reserve_offers[player_name][item_name]
      if not old_reserve then
        storage.reserve_offers[player_name][item_name] = {price = price , ordering = nil}
      else
        storage.reserve_offers[player_name][item_name].price = price
      end
  end)
end

function harberger_economy.get_default_price(item_name)
  local price_index = harberger_economy.config.price_index
  local time = minetest.get_gametime()
  local time_speed = minetest.settings:get('time_speed') or TIME_SPEED
  return harberger_economy.round(price_index * time * time_speed / 24 / 60 / 60)
end


-- END public storage api


-- minetest.register_on_joinplayer(
--   function(ObjectRef)
--     print("harberger_economy (on_joinplayer): " .. dump(ObjectRef))
--   end
-- )

-- minetest.register_on_placenode(
--   function(pos, newnode, placer, oldnode, itemstack, pointed_thing)
--     local meta = minetest.get_meta(pos)
--     print("harberger_economy (on_placenode): "
--             .. dump(pos) .. " "
--             .. dump(newnode) .. " "
--             .. dump(placer) .. " "
--             .. dump(oldnode) .. " "
--             .. dump(itemstack) .. " "
--             .. dump(pointed_thing) .. " "
--             .. dump(meta:to_table()) .. " "
--     )



--   end
-- )

--[[
When a player gets a new item if there is no reserve price
  1. Set the reserve price to current selling price +10%
  2. If there is no selling price then set it to game_time / days * daily_price_basket
  (i.e. it took this much game time to get so it's probably worth that)
--]]



local function update_inventory(player, inventory)
  local player_name = player:get_player_name()
  for list_name, list in pairs(inventory:get_lists()) do
    if list_name ~= 'craftpreview' then -- ignore craftpreview since it's a 'virtual' item
      for index, item_stack in ipairs(list) do
        local item_name = item_stack:get_name()
        local reserve_offer = harberger_economy.get_reserve_offer(player_name, item_name)
        if not reserve_offer then
          local price = harberger_economy.get_default_price(item_name)
          minetest.chat_send_player(
            player_name,
            "You have not set a reserve price for "
              .. item_name .. " setting it to " .. price)
          harberger_economy.log(
            'action',
            player_name .. " has not set a reserve price for "
              .. item_name .. " setting it to " .. price)
          harberger_economy.set_reserve_price(player_name, item_name, price)
        end
        -- print(list_name .. '[' .. index  .. ']' .. " = " .. item_stack:to_string())
      end
    end
  end
end

local function update_player(player)
  local player_name = player:get_player_name()
  if not harberger_economy.is_player_initialized(player_name) then
    harberger_economy.initialize_player(player_name)
  end
  -- can replace with minetest.register_on_player_inventory_action(function(player, action, inventory, inventory_info))`
  update_inventory(player, player:get_inventory())
end



local function update_function(dtime)
  harberger_economy.batch_storage(
    function ()
      local connected_players = minetest.get_connected_players()
      for i, player in ipairs(connected_players) do
        update_player(player)
      end
    end
  )
end


local update_timediff = harberger_economy.config.update_delay
minetest.register_globalstep(
  function (dtime)
    update_timediff = update_timediff + dtime
    if update_timediff >= harberger_economy.config.update_delay then
      update_function(update_timediff)
      update_timediff = 0
    end
  end
)
