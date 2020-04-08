harberger_economy = {}

-- BEGIN Load config

-- NOTE minetest.settings.get will return null if the setting is not set by the
-- user (and not the default value). Thus default values must be duplicated
-- here. Take care to keep them in sync.

-- THINGS I've learned
-- get_meta will emerge a chunk if it's not emerged yet
-- player metadata is only accessible when the player is logged in
-- detached inventories don't last across restarts

local function settings_get_number(s, default)
  -- unfortunately settings:get always gets a string (or nil) so we have to convert to number
  local t = minetest.settings:get(s)
  if t then
    return tonumber(t)
  else
    return default
  end
end

local persistent_inventory_get_items

harberger_economy.config = {
  starting_income = settings_get_number('harberger_economy.starting_income', 10000),
  update_delay = settings_get_number('harberger_economy.update_delay', 1),
  price_index = settings_get_number('harberger_economy.price_index', 10000),
  payment_frequency = settings_get_number('harberger_economy.payment_frequency', 1),
  default_tax_rate_bp = settings_get_number('harberger_economy.default_tax_rate_bp', 10),
  money_supply_rate_limit = settings_get_number('harberger_economy.money_supply_rate_limit', 10),
  auction_percentage = settings_get_number('harberger_economy.auction_percentage', 20),
}

-- This is a default constant in minetest, but I can't seem to find it anywhere,
-- so I'm going to hard code 72.
local TIME_SPEED = minetest.settings:get('time_speed') or 72

local DAY_SECONDS = 24 * 60 * 60

-- END Load config

-- BEGIN helper methods

function harberger_economy.log(logtype, logmessage)
  minetest.log(logtype, 'harberger_economy: ' .. logmessage)
end

function harberger_economy.log_chat(logtype, logmessage, players)
  harberger_economy.log(logtype, logmessage)
  -- TODO use minetest colourize
  for i, player in ipairs(players) do
    minetest.chat_send_player(player, logmessage)
  end
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

local function too_few_players()
  return #minetest.get_connected_players() < 2
end

-- END helper methods

-- "name" of the bank
harberger_economy.the_bank = "%THEBANK%"

-- BEGIN Private storage api

harberger_economy.storage = minetest.get_mod_storage()

local default_data = {
  offers = {
  },
  reserve_offers = {
    -- key is username to a table with
    -- key as item name to a table
    -- {price = 103, ordering = {nil or list of locations for the prefered ordering to take items }}
  },
  balances = {
    [harberger_economy.the_bank] = 0, -- special
  },
  transactions = {
  },
  initialized_players = {
    -- contains key-value pair of player and bool, is nil if not initialized and true if initialized
  },
  inventory_change_list = {
    -- See persistent inventory
  },
  detached_inventories = {
    -- See persistent inventory
  },
  time_since_last_payment = 0,
  quantity_days = {
    -- Quantity of an item on the market integrated over the number of days in the market
  },
  total_buys = {
    -- Number of times an item has been bought
  },
  pos_to_region = {
  },
  region_to_owner = {
  },
  region_to_price = {
  },
  region_node_count = {
  },
  last_region = 0,
  claim_on_place = {
    -- Setting for whether nodes should be claimed when placed
  },
}

local current_schema = '18'
local cached_storage = nil
local batch_storage = 0


local function upgrade_schema_from_17(data_with_schema)
  -- Disable claim on place by default, because it is weird
  data_with_schema.schema = '18'
  for p, b in pairs(data_with_schema.data.claim_on_place) do
    data_with_schema.data.claim_on_place[p] = false
  end
  return data_with_schema
end

local function upgrade_schema(data_with_schema)
  if data_with_schema.schema == '17' then
    data_with_schema = upgrade_schema_from_17(data_with_schema)
  end
  if data_with_schema.schema == current_schema then
    return data_with_schema.data
  end
  data_with_schema.schema = current_schema
  data_with_schema.data = default_data
  return data_with_schema
end

-- TODO I think it should be fine to only save_storage at intervals and on server exit
-- and only get storage at start. Otherwise we can manipulated cached_storage directly
function harberger_economy.get_storage()
  if batch_storage == 0 then
    local data_string = harberger_economy.storage:get('data')
    if not data_string then
      cached_storage = default_data
    else
      -- TODO deserialization takes about 5ms on a small world which is too slow to run every tick
      local data_with_schema = minetest.deserialize(data_string)
      cached_storage = upgrade_schema(data_with_schema)
      if not data_with_schema or data_with_schema.schema ~= current_schema then
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
    -- local start = minetest.get_us_time()
    local data_with_schema = {
      schema = current_schema,
      data = data,
    }
    -- local thing = minetest.get_us_time()
    -- TODO Serialization takes about 5ms on a small world, which is too slow to run every tick
    -- The best things is probably only run this every server_map_save_interval
    local data_string = minetest.serialize(data_with_schema)
    -- local last_thing = minetest.get_us_time()
    harberger_economy.storage:set_string('data', data_string)
    -- local last = minetest.get_us_time()
    -- print("Saving took " .. (last - start) .. "us."
    -- .. "Serializing took " .. (last_thing - thing) .. "us. String size " .. #data_string)
  end
end

function harberger_economy.with_storage(func)
  local storage = harberger_economy.get_storage()
  batch_storage = batch_storage + 1
  local return_value = {func(storage)}
  batch_storage = batch_storage - 1
  harberger_economy.set_storage(storage)
  return unpack(return_value)
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

-- TODO all this functions should validate all their inputs
-- TODO logging should put tostring around args since a failure might be caused by non string type

function harberger_economy.initialize_player(player)
  return harberger_economy.with_storage(function (storage)
      local player_name = player:get_player_name()
      if storage.initialized_players[player_name] then
        harberger_economy.log('warning', 'Player ' .. player_name .. ' is already initialized, ignoring.' )
      else
        harberger_economy.log('action', 'Initializing ' .. player_name)
        storage.offers[player_name] = {}
        storage.reserve_offers[player_name] = {}
        storage.initialized_players[player_name] = true
        storage.balances[player_name] = 0
        storage.transactions[player_name] = {}
        storage.inventory_change_list[player_name] = {}
        storage.claim_on_place[player_name] = false
      end
  end)
end

function harberger_economy.is_player_initialized(player_name)
  return harberger_economy.with_storage(function (storage)
      return not not storage.initialized_players[player_name]
  end)
end

function harberger_economy.get_players()
  return harberger_economy.with_storage(function (storage)
      local players = {}
      for player, b in pairs(storage.initialized_players) do
        if b then
          table.insert(players, player)
        end
      end
      return players
  end)
end


function harberger_economy.get_reserve_offers(player_name)
  return harberger_economy.with_storage(function (storage)
      return storage.reserve_offers[player_name]
  end)
end

function harberger_economy.get_reserve_offer(player_name, item_name)
  return harberger_economy.with_storage(function (storage)
      return storage.reserve_offers[player_name][item_name]
  end)
end

function harberger_economy.is_item(item_name)
  return minetest.registered_items[item_name] and item_name ~= ''
end

function harberger_economy.is_region(region)
  return harberger_economy.with_storage(
    function (storage)
      if storage.region_to_owner[region] then
        return true
      else
        return false
      end
    end
  )
end


function harberger_economy.get_time_since_last_payement()
  return harberger_economy.with_storage(
    function (storage)
      return storage.time_since_last_payment
    end
  )
end

function harberger_economy.set_reserve_price(player_name, item_name, price)
  return harberger_economy.with_storage(function (storage)
      if not harberger_economy.is_item(item_name) then
        harberger_economy.log(
          'warning',
          "Tried to set price of non-existent item "
            .. tostring(item_name) .. ". Ignoring."
        )
        return
      end
      price = tonumber(price)
      if not price then
        harberger_economy.log(
          'warning',
          "Tried to set invalid price of item " .. item_name
            .. ". Ignoring."
        )
        return
      end
      if price < 0 then
        -- While in theory negative valuations should be possible (I would pay
        -- for you to take this off my hands), but it becomes messy when the person
        -- can't actually afford to pay. So we disallow it.
        harberger_economy.log(
          'warning',
          "Tried to set price of item " .. item_name
            .. " to a negative number. Ignoring."
        )
        return
      end
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
  --[[
    When a player gets a new item if there is no reserve price
    1. Set the reserve price to current selling price
    2. If there is no selling price then set it to game_time / days * daily_price_basket
       (i.e. it took this much game time to get so it's probably worth that)
    3. However if the item is more expensive than 1 day
       set the price to no more than 2 twice the most expensive item
       to prevent items so expensive it immediately bankrupts a player
  --]]
  local cheapest_offers = harberger_economy.get_cheapest_offers()
  if cheapest_offers[item_name] then
    return cheapest_offers[item_name]
  else
      local price_index = harberger_economy.config.price_index
      local time = minetest.get_gametime()
      local time_speed =  TIME_SPEED
      local time_is_money = price_index * time * time_speed / DAY_SECONDS
      local price = time_is_money
      if time_is_money > price_index then
        local most_expensive = harberger_economy.get_most_expensive_offer()
        if most_expensive and most_expensive.price > 0 then
          price = math.min(price, most_expensive.price * 2)
        end
      end
      return harberger_economy.round(price)
  end
end

function harberger_economy.reason_to_string(reason)
  if reason then
      if reason.type == 'daily_income' then
        return 'Daily income'
      elseif reason.type == 'buy' then
        return 'Bought ' .. reason.item_stack
      elseif reason.type == 'harberger_tax' then
        return 'Tax'
      elseif reason.type == 'bankruptcy' then
        return 'Bankruptcy'
      elseif reason.type == 'buy_region' then
        return 'Bought ' .. reason.region
      end
  end
  harberger_economy.log('warn', 'Reason for payment' .. dump(reason) .. ' is unknown.')
  return dump(reason)
end

function harberger_economy.pay(from, to, amount, reason, can_be_negative)
  return harberger_economy.with_storage(function (storage)
      from = from or harberger_economy.the_bank
      to = to or harberger_economy.the_bank
      amount = harberger_economy.round(amount)
      local time = minetest.get_gametime()
      local reason_string = harberger_economy.reason_to_string(reason)
      local transfer_string = 'Transferring (' .. reason_string .. ') '
        .. amount
        .. ' from ' .. from
        .. ' to ' .. to
      local from_new_balance
      local to_new_balance
      if from ~= to then
        from_new_balance = storage.balances[from] - amount
        to_new_balance = storage.balances[to] + amount
      else
        from_new_balance = storage.balances[from]
        to_new_balance = storage.balances[to]
        can_be_negative = true -- we are not changing balance, so this check is useless
      end
      if not can_be_negative then
        if (from ~= harberger_economy.the_bank and from_new_balance < 0 and amount > 0)
          or (to ~= harberger_economy.the_bank and to_new_balance < 0 and amount < 0)
        then
          harberger_economy.log(
            'warning',
            transfer_string
              .. ' would result in a negative balance. Ignoring.'
          )
          return false
        end
      end
      harberger_economy.log('action', transfer_string  .. '.')
      if from ~= harberger_economy.the_bank then
        minetest.chat_send_player(from, transfer_string .. '.')
      end
      if to ~= harberger_economy.the_bank and from ~= to then
        minetest.chat_send_player(to, transfer_string .. '.')
      end
      storage.balances[from] = from_new_balance
      storage.balances[to] = to_new_balance
      table.insert(storage.transactions,
                   {time=time, from=from, to=to, amount=amount, reason=reason}
      )
      return true
  end)
end

function harberger_economy.get_balance(player_name)
  return harberger_economy.with_storage(
    function (storage)
      return storage.balances[player_name]
    end
  )
end

function harberger_economy.get_offers(buying_player_name)
  return harberger_economy.with_storage(
    function(storage)
      local offers = {}
      -- Player inventory offers
      for player_name, b in pairs(storage.initialized_players) do
        if b and player_name ~= buying_player_name then
          local inv_list = persistent_inventory_get_items(player_name)
          for list_name, list in pairs(inv_list) do
            if list_name ~= 'craftpreview' then
              for index, item in ipairs(list) do
                if not item:is_empty() then
                  local item_name = item:get_name()
                  if not offers[item_name] then
                    offers[item_name] = {}
                  end
                  local offer = {}
                  offer.location = {type='player', name=player_name}
                  offer.player_name = player_name
                  local try_offer_price = harberger_economy.get_reserve_offer(player_name, item_name)
                  if try_offer_price then
                    offer.price = try_offer_price.price
                    offer.count = item:get_count()
                    table.insert(offers[item_name], offer)
                  else
                    -- TODO we have to do nothing here because calling initialize
                    -- _reserve_price causes a recursive infinite loop
                  end
                end
              end
            end
          end
        end
      end
      -- Player chest offers
      for i, pos in ipairs(harberger_economy.get_owned_pos()) do
        local location = {type='node', pos=pos}
        local player_name =  harberger_economy.get_owner_of_pos(pos)
        local inv = minetest.get_inventory(location)
        if inv and player_name ~= buying_player_name then
          for list_name, list in pairs(inv:get_lists()) do
            for index, item in ipairs(list) do
              if not item:is_empty() then
                local item_name = item:get_name()
                offers[item_name] = offers[item_name] or {}
                local offer = {location=location, player_name=player_name}
                local try_offer_price = harberger_economy.get_reserve_offer(player_name, item_name)
                if try_offer_price then
                  offer.price = try_offer_price.price
                  offer.count = item:get_count()
                  table.insert(offers[item_name], offer)
                end
              end
            end
          end
        end
      end
      return offers
    end
  )
end

function harberger_economy.get_cheapest_offers(buying_player_name)
  local offers = harberger_economy.get_offers(buying_player_name)
  local cheapest_offers = {}
  for item_name, offer_list in pairs(offers) do
    for i, offer in ipairs(offer_list) do
      if not cheapest_offers[item_name] then
        cheapest_offers[item_name] = offer.price
      else
        cheapest_offers[item_name] = math.min(cheapest_offers[item_name], offer.price)
      end
    end
  end
  return cheapest_offers
end

function harberger_economy.get_most_expensive_offer()
  local offers = harberger_economy.get_offers()
  local expensive_offer = {price=0}
  for item_name, offer_list in pairs(offers) do
    for i, offer in ipairs(offer_list) do
      if expensive_offer.price < offer.price then
        expensive_offer = offer
      end
    end
  end
  return expensive_offer
end

function harberger_economy.reposses_assets(player_name)
  local inv_list = persistent_inventory_get_items(player_name)
  for list_name, list in pairs(inv_list) do
    for index, item in ipairs(list) do
      persistent_inventory_try_to_remove_one(player_name, item:to_string())
    end
  end
  local owned_pos = harberger_economy.get_owned_pos(player_name)
  for i, pos in ipairs(owned_pos) do
    harberger_economy.set_region(pos, nil)
    minetest.remove_node(pos)
  end
  local owned_regions = harberger_economy.get_owned_regions(player_name)
  for i, region in ipairs(owned_regions) do
    harberger_economy.delete_region(region)
  end
end

local function on_successful_buy(item_name)
  return harberger_economy.with_storage(
    function (storage)
      local total_buys = storage.total_buys[item_name]
      if not total_buys then
        total_buys = 0
      end
      storage.total_buys[item_name] = total_buys + 1
    end
  )
end

local function handle_price_signal(player_name, item_name, price)
  local offer = harberger_economy.get_reserve_offer(player_name, item_name)
  local old_price = (offer and offer.price) or 0
  if old_price < price then
    minetest.chat_send_player(
      player_name,
      "Reserve price for " .. item_name .. "increased to buying price of " .. price .. "."
    )
    harberger_economy.set_reserve_price(player_name, item_name, price)
  end
end

function harberger_economy.buy(player_name, item_name)
  return harberger_economy.with_storage(
    function (storage)
      if too_few_players() then
        harberger_economy.log_chat("warning", "Economy is disabled since too few players are online.", {player_name})
        return false
      end
      local player = minetest.get_player_by_name(player_name)
      if not player then
        -- We need player location in case inventory full to drop item. Buying
        -- while not logged in is currently not supported
        harberger_economy.log('error', player_name .. " tried to buy an item without being logged in")
        return false
      end
      local offers = harberger_economy.get_offers(player_name)[item_name]
      if not offers then
        harberger_economy.log(
          'warning',
          tostring(player_name)
            .. ' tried to buy ' .. tostring(item_name)
            .. ' but no offers were available.'
        )
        return false
      end
      table.sort(offers, function (a, b) return a.price < b.price end)
      for i, offer in ipairs(offers) do
        if offer.location.type ~= 'player' and offer.location.type ~= 'node' then
          harberger_economy.log('error', 'Operation not supported yet: Tried to buy from a detached inventory.')
        else
          -- If the player was willing to buy at the price his reserve price
          -- should be higher
          handle_price_signal(player_name, item_name, offer.price)
          local seller = offer.player_name
          local success
          local removed_from_list
          if offer.location.type == 'player' then
            success, removed_from_list = persistent_inventory_try_to_remove_one(seller, item_name)
          elseif offer.location.type == 'node' then
            local inv = minetest.get_inventory(offer.location)
            success = false
            for list_name, list in pairs(inv:get_lists()) do
              local item = inv:remove_item(list_name, item_name)
              if not item:is_empty() then
                success = true
              end
            end
          else
            harberger_economy.log('error', "this is impossible")
          end
          if success then
            local reason = {type='buy', buyer=player_name, seller=seller, item_stack=item_name, offer=offer}
            local pay = harberger_economy.pay(player_name, seller, offer.price, reason, false)
            if not pay then
              persistent_inventory_try_to_add_one(seller, removed_from_list, item_name)
              local error_string = "Cannot buy " .. tostring(item_name) .. ". Not enough funds."
              minetest.chat_send_player(player_name, error_string)
              harberger_economy.log('warning', tostring(player_name) .. " " .. error_string)
              return false
            else
              local result = persistent_inventory_try_to_add_one(player_name, 'main', item_name)
              if not result then
                -- TODO reverse this transaction
                -- We just drop the item as it is convenient
                minetest.item_drop(ItemStack(item_name), player, player:get_pos())
              end
              on_successful_buy(item_name)
              return true
            end
          end
        end
      end
      return true
    end
  )
end

-- Returns the tax rate in basis points (1/10000ths or 1/100 of a percent)
function harberger_economy.get_tax_rate_bp(item_name)
  return harberger_economy.with_storage(
    function (storage)
      local quantity_days = storage.quantity_days[item_name]
      local buys = storage.total_buys[item_name]
      if not quantity_days or not buys or buys == 0 or quantity_days == 0 then
        return harberger_economy.config.default_tax_rate_bp
      end
      local computed_tax_rate = harberger_economy.round(buys / quantity_days * 10000)
      -- When we have very little information the tax rate can be horrendously
      -- wrong. Information can be measured by how large the quantities are. So
      -- we use them as caps.
      local scale = harberger_economy.config.default_tax_rate_bp
      local capped_rate = math.min(
        computed_tax_rate,
        math.max(buys * scale, quantity_days * scale)
      )
      -- We don't want the rate to be too small either
      local final_rate = math.max(capped_rate, scale)
      return harberger_economy.round(final_rate)
    end
  )
end

-- Returns the tax rate in basis points (1/10000ths or 1/100 of a percent)
-- Weighted average of tax of all items multiplied by log2 of number of items + 1
function harberger_economy.get_tax_rate_region_bp(region)
  return harberger_economy.with_storage(
    function (storage)
      local total = 0
      local tax_rate = 0
      for item_name, count in pairs(storage.region_node_count[region]) do
        total = total + count
        local item_tax = harberger_economy.get_tax_rate_bp(item_name)
        tax_rate = tax_rate + count * item_tax
      end
      tax_rate = tax_rate / total
      local size_multiplier = 1 + math.log(total) / math.log(2)
      tax_rate = size_multiplier * tax_rate
      return harberger_economy.round(tax_rate)
    end
  )
end


function harberger_economy.get_tax_per_item(player_name)
  return harberger_economy.batch_storage(
    function()
      local offers = harberger_economy.get_offers(nil)
      local tax = {}
      for item_name, offer_list in pairs(offers) do
        local tax_rate =  harberger_economy.get_tax_rate_bp(item_name) / 10000
        local total_tax = 0
        local count = 0
        for i, offer in ipairs(offer_list) do
          if offer.player_name == player_name then
            count = count + offer.count
            total_tax = total_tax + offer.price * offer.count * tax_rate
          end
        end
        if count > 0 then
          local average_price = total_tax / count / tax_rate
          tax[item_name] = {tax_rate=tax_rate, count=count,
                            total_tax=total_tax, average_price=average_price}
        end
      end
      return tax
    end
  )
end

function harberger_economy.get_tax_per_region(player_name)
  return harberger_economy.batch_storage(
    function()
      local regions = harberger_economy.get_owned_regions(player_name)
      local tax = {}
      for i, region in ipairs(regions) do
        local tax_rate =  harberger_economy.get_tax_rate_region_bp(region) / 10000
        local price = harberger_economy.get_region_price(region)
        local total_tax = price * tax_rate
        if total_tax > 0 then
          tax[region] = {tax_rate=tax_rate, total_tax=total_tax, price=price}
        end
      end
      return tax
    end
  )
end

function harberger_economy.get_tax_owed(player_name)
  local tax_per_item = harberger_economy.get_tax_per_item(player_name)
  local tax = 0
  for item_name, tax_entry in pairs(tax_per_item) do
    tax = tax + tax_entry.total_tax
  end
  local tax_per_region = harberger_economy.get_tax_per_region(player_name)
  for region, tax_entry in pairs(tax_per_region) do
    tax = tax + tax_entry.total_tax
  end
  return tax
end

function harberger_economy.get_wealth(player_name)
  local tax_per_item = harberger_economy.get_tax_per_item(player_name)
  local wealth = 0
  for item_name, tax_entry in pairs(tax_per_item) do
    wealth = wealth + tax_entry.average_price * tax_entry.count
  end
  for i, region in pairs(harberger_economy.get_owned_regions(player_name)) do
    wealth = wealth + harberger_economy.get_region_price(region)
  end
  return wealth
end

function harberger_economy.get_basket_price()
  return harberger_economy.with_storage(
    function (storage)
      -- Get's the price of the goods basket, used for inflation targeting.
      -- The basket is the basket of goods people buy in a single day on average
      local prices = harberger_economy.get_cheapest_offers()
      local basket = 0
      local days = minetest.get_gametime() / DAY_SECONDS * TIME_SPEED
      for item_name, count in pairs(storage.total_buys) do
        local price = prices[item_name]
        if not price then
          price = 0
        end
        basket = basket + count / days * price
      end
      return harberger_economy.round(basket)
    end
  )
end

function harberger_economy.get_region(pos)
  return harberger_economy.with_storage(
    function (storage)
      return (((storage.pos_to_region[pos.x] or {})[pos.y]) or {})[pos.z]
    end
  )
end

function harberger_economy.get_owner_of_region(region)
  return harberger_economy.with_storage(
    function (storage)
      return storage.region_to_owner[region]
    end
  )
end

function harberger_economy.get_owner_of_pos(pos)
  local region = harberger_economy.get_region(pos)
  if region then
    local owner = harberger_economy.get_owner_of_region(region)
    return owner
  end
end

function harberger_economy.is_not_owner(player_name, pos)
  local owner = harberger_economy.get_owner_of_pos(pos)
  if owner and player_name ~= owner then
    return true
  end
  return false
end

function harberger_economy.set_region(pos, region)
  return harberger_economy.with_storage(
    function (storage)
      if not storage.pos_to_region[pos.x] then
        storage.pos_to_region[pos.x] = {}
      end
      if not storage.pos_to_region[pos.x][pos.y] then
        storage.pos_to_region[pos.x][pos.y] = {}
      end
      storage.pos_to_region[pos.x][pos.y][pos.z] = region
    end
  )
end

function harberger_economy.add_node_to_region(pos, region, node)
  return harberger_economy.with_storage(
    function (storage)
      harberger_economy.set_region(pos, region)
      local player_name = harberger_economy.get_owner_of_region(region)
      if node and node.name then
        local node_offer = harberger_economy.get_reserve_offer(player_name, node.name) or {price=0}
        harberger_economy.increase_region_price(region, node_offer.price)
        local rnc = storage.region_node_count[region]
        rnc[node.name] = rnc[node.name] or 0
        rnc[node.name] = rnc[node.name] + 1
      end
    end
  )
end



function harberger_economy.surrounding_regions(pos)
  return harberger_economy.with_storage(
    function (storage)
      local surrounding_areas = {}
      for dx = -1,1 do
        for dy = -1,1 do
          for dz = -1,1 do
            if dx ~= 0 or dy ~= 0 or dz ~= 0 then
              local new_pos = {x = pos.x + dx, y = pos.y + dy, z = pos.z + dz}
              local region = harberger_economy.get_region(new_pos)
              if region then
                surrounding_areas[region] = true
              end
            end
          end
        end
      end
      return surrounding_areas
    end
  )
end

-- Merge small into large
function harberger_economy.merge_region(large, small)
  harberger_economy.with_storage(
    function (storage)
      if small == large then
        harberger_economy.log('warn', "Tried to merge an area with itself. Ignoring")
        return
      end
      for x, a in pairs(storage.pos_to_region) do
        for y, b in pairs(a) do
          for z, region in pairs(b) do
            if region == small then
              storage.pos_to_region[x][y][z] = large
            end
          end
        end
      end
      harberger_economy.increase_region_price(large, storage.region_to_price[small])
      harberger_economy.delete_region(small)
    end
  )
end

function harberger_economy.new_region(new_owner)
  return harberger_economy.with_storage(
    function (storage)
      local my_region = storage.last_region + 1
      storage.last_region = my_region
      storage.region_to_owner[my_region] = new_owner
      storage.region_to_price[my_region] = 0
      storage.region_node_count[my_region] = {}
      return my_region
    end
  )
end

function harberger_economy.delete_region(region)
   return harberger_economy.with_storage(
    function (storage)
      storage.region_to_owner[region] = nil
      storage.region_to_price[region] = nil
      storage.region_node_count[region] = nil
    end
  )
end

function harberger_economy.claim_node(player_name, pos, node)
  return harberger_economy.with_storage(
    function (storage)
      local surrounding = harberger_economy.surrounding_regions(pos)
      local my_surrounding = {}
      for region, b in pairs(surrounding) do
        if storage.region_to_owner[region] == player_name then
          table.insert(my_surrounding, region)
        end
      end
      local region
      if #my_surrounding == 0 then
        region = harberger_economy.new_region(player_name)
      elseif #my_surrounding == 1 then
        region = my_surrounding[1]
      else
        region = my_surrounding[1]
        for i, r in ipairs(my_surrounding) do
          if i ~= 1 then
            harberger_economy.merge_region(region, r)
          end
        end
      end
      harberger_economy.add_node_to_region(pos, region, node)
    end
  )
end

function harberger_economy.disown_node(pos, node)
  return harberger_economy.with_storage(
    function (storage)
      local player_name = harberger_economy.get_owner_of_pos(pos)
      if player_name then
        local region = harberger_economy.get_region(pos)
        if node and node.name then
          local offer = {price=0}
          offer = harberger_economy.get_reserve_offer(player_name, node.name) or offer
          harberger_economy.increase_region_price(region, -offer.price)
          local rnc = storage.region_node_count[region]
          rnc[node.name] = rnc[node.name] or 1
          rnc[node.name] = rnc[node.name] - 1
        end
      end
      harberger_economy.set_region(pos, nil)
    end
  )
end

function harberger_economy.get_region_price(region)
  return harberger_economy.with_storage(
    function (storage)
      return storage.region_to_price[region]
    end
  )
end


function harberger_economy.increase_region_price(region, incr)
  return harberger_economy.with_storage(
    function (storage)
      local new_price = storage.region_to_price[region] + incr
      new_price = math.max(0, new_price)
      storage.region_to_price[region] = new_price
    end
  )
end

function harberger_economy.set_region_price(region, price)
  return harberger_economy.with_storage(
    function (storage)
      local new_price = math.max(0, price)
      if new_price == 0 then
        harberger_economy.delete_region(region)
      else
        storage.region_to_price[region] = new_price
      end

    end
  )
end

function harberger_economy.set_region_owner(region, owner)
  return harberger_economy.with_storage(
    function (storage)
      if storage.initialized_players[owner] then
        storage.region_to_owner[region] = owner
      end
    end
  )
end

function harberger_economy.buy_region(player_name, region)
  return harberger_economy.with_storage(
    function (storage)
      if too_few_players() then
        harberger_economy.log_chat('warning', "Economy is disabled since too few players are online", {player_name})
        return false
      end
      local seller = harberger_economy.get_owner_of_region(region)
      local price = harberger_economy.get_region_price(region)
      if not seller or seller == player_name then
        return false -- Don't buy from yourself or null
      end
      local reason = {type='buy_region', buyer=player_name, seller=seller, region=region}
      local pay = harberger_economy.pay(player_name, seller, price, reason, false)
      if not pay then
        local error_string =  tostring(player_name) .. " cannot buy " .. tostring(region) .. ". Not enough funds."
        harberger_economy.log_chat('warning', error_string, {player_name})
        return false
      else
        harberger_economy.set_region_owner(region, player_name)
        return true
      end
    end
  )
end

-- END public storage api

-- BEGIN Persistent Inventory api

-- TODO can probably split this out into a separate mod

--[[
When players leave the server the inventory is no longer accessible.
This is a simple api for harberger_economy that lets you "edit" a virtual
copy of the players inventory, which is kept in sync with the real inventory.

We have a one way dataflow of

write -> inventory_change_list -> inventory -> (write -> inventory_copy) --> read

Everytime we want to change the inventory we edit the inventory_change_list and
the inventory_copy directly. A timer moves changes from the inventory_change
list to the inventory and then to the inventory_copy. When we need to read from
the inventory we read from the inventory copy
--]]

local function get_inventory_copy_name(player_name)
  return 'harberger_economy:persistent_player:' .. player_name
end

local function create_ro_detached_inventory(inventory_name)
  minetest.create_detached_inventory(
    inventory_name,
    {
      allow_move = function (inv, from_list, from_index, to_list, to_index, count, plyer)
        return 0
      end,
      allow_put = function (inv, listname, index, stack, plyer)
        return 0
      end,
      allow_take = function (inv, listname, index, stack, plyer)
        return 0
      end,
      on_move = function (inv, from_list, from_index, to_list, to_index, count, plyer)
        -- print('moved')
      end,
      on_put = function (inv, listname, index, stack, plyer)
        -- print('put')
      end,
      on_take = function (inv, listname, index, stack, plyer)
        -- print('take')
      end,
    }
  )
  return minetest.get_inventory({type="detached", name=inventory_name})
end

local function apply_change_to_inventory(change, inventory)
  if change.type == 'remove' then
    return inventory:remove_item(change.list_name, change.item_stack)
  elseif change.type == 'add' then
    return inventory:add_item(change.list_name, change.item_stack)
  end
end

local function store_detached_inventory(inventory_name)
  harberger_economy.with_storage(
    function (storage)
      local inv = minetest.get_inventory({type="detached", name=inventory_name})
      local serialized = {}
      for list_name, list_value in pairs(inv:get_lists()) do
        local width = inv:get_width(list_name)
        local size = inv:get_size(list_name)
        serialized[list_name] = {width=width, size=size, value={}}
        for i, item in ipairs(list_value) do
          serialized[list_name].value[i] = item:to_string()
        end
      end
      storage.detached_inventories[inventory_name] = serialized
    end
  )
end

local function add_inventory_change(player_name, change)
  harberger_economy.with_storage(
    function (storage)
      table.insert(storage.inventory_change_list[player_name], change)
    end
  )
end

local function update_persistent_inventory(player)
  harberger_economy.with_storage(
    function (storage)
      local player_name = player:get_player_name()
      local player_inv = minetest.get_inventory({type="player", name=player_name})
      -- BEGIN Apply changelist
      local list = storage.inventory_change_list[player_name]
      for i, a in ipairs(list) do
        apply_change_to_inventory(a, player_inv)
      end
      storage.inventory_change_list[player_name] = {}
      -- END Apply changelist
      -- BEGIN Copy inventory
      local inventory_name = get_inventory_copy_name(player_name)
      local copy_inv = create_ro_detached_inventory(inventory_name)
      for list_name, list_value in pairs(player_inv:get_lists()) do
        local width = player_inv:get_width(list_name)
        local size = player_inv:get_size(list_name)
        copy_inv:set_size(list_name, size)
        copy_inv:set_width(list_name, width)
        copy_inv:set_list(list_name, list_value)
      end
      store_detached_inventory(inventory_name)
      -- END Copy Inventory
    end
  )
end

local function restore_detached_inventory(inventory_name)
  harberger_economy.with_storage(
    function (storage)
      local inv = storage.detached_inventories[inventory_name]
      local copy_inv = create_ro_detached_inventory(inventory_name)
      for list_name, list_config in pairs(inv) do
        copy_inv:set_size(list_name, list_config.size)
        copy_inv:set_width(list_name, list_config.width)
        copy_inv:set_list(list_name, list_config.value)
      end
    end
  )
end

local function get_persistent_detached_inventory(inventory_name)
  local copy_inv = minetest.get_inventory({type="detached", name=inventory_name})
  if not copy_inv then
    restore_detached_inventory(inventory_name)
    copy_inv = minetest.get_inventory({type="detached", name=inventory_name})
  end
  return copy_inv
end

function persistent_inventory_get_items(player_name)
  local inventory_name = get_inventory_copy_name(player_name)
  local copy_inv = get_persistent_detached_inventory(inventory_name)
  local lists = copy_inv:get_lists()
  lists['craftpreview'] = nil -- We don't care about craft preview
  return lists
end

function persistent_inventory_try_to_add_one(player_name, list_name, item_name)
  local inventory_name = get_inventory_copy_name(player_name)
  local copy_inv = get_persistent_detached_inventory(inventory_name)
  local change = {type='add', list_name=list_name, item_stack=item_name}
  local result = apply_change_to_inventory(change, copy_inv)
  add_inventory_change(player_name, change)
  if result:is_empty() then
    return true
  end
  return false
end


function persistent_inventory_try_to_remove_one(player_name, item_name)
  local inventory_name = get_inventory_copy_name(player_name)
  local copy_inv = get_persistent_detached_inventory(inventory_name)
  for list_name, list in pairs(copy_inv:get_lists()) do
    if list_name ~= 'craftpreview' then
      local change = {type='remove', list_name=list_name, item_stack=item_name}
      local result = apply_change_to_inventory(change, copy_inv)
      add_inventory_change(player_name, change)
      if not result:is_empty() then
        return true, list_name
      end
    end
  end
  return false, nil
end

-- END Persistent Inventory api

-- BEGIN other api

local item_button_prefix = "item_button:"

local function insert_item_table(x, y, columns, rows, offer_list, form_spec)
  table.insert(form_spec, 'container[')
  table.insert(form_spec, x)
  table.insert(form_spec, ',')
  table.insert(form_spec, y)
  table.insert(form_spec, ']')
  for i, offer in ipairs(offer_list) do
    table.insert(form_spec, 'item_image_button[')
    table.insert(form_spec, (i - 1) % columns)
    table.insert(form_spec, ',')
    table.insert(form_spec, math.floor((i - 1) / columns))
    table.insert(form_spec, ';1.1,1.1;')
    table.insert(form_spec, offer.item)
    table.insert(form_spec, ';')
    table.insert(form_spec, item_button_prefix)
    table.insert(form_spec, offer.item)
    table.insert(form_spec, ';')
    table.insert(form_spec, offer.label)
    table.insert(form_spec, ']')
  end
  table.insert(form_spec, 'container_end[]')
end

local function get_item_button_pressed(fields)
  for k, v in pairs(fields) do
    if k:sub(1, #item_button_prefix) == item_button_prefix then
      local item_name = k:sub(#item_button_prefix + 1, #k)
      return item_name
    end
  end
  return nil
end

local function get_best_dimensions(num_items, max_rows)
  local min_columns = 8
  if max_rows == nil then
    max_rows = 12 -- From trail and error this seems reasonable
  end
  if num_items <= max_rows * min_columns then
    local rows = math.ceil(num_items / min_columns)
    return rows, min_columns
  else
    local columns = math.ceil(num_items/max_rows)
    return max_rows, columns
  end
end

function harberger_economy.show_buy_form(player_name)
  local form_name = 'harberger_economy:buy_form'
  local offers = harberger_economy.get_cheapest_offers(player_name)
  local offer_list = {}
  for item, price in pairs(offers) do
    table.insert(offer_list, {item=item, label=price})
  end
  table.sort(offer_list, function (a, b) return a.item < b.item end)
  local rows, columns = get_best_dimensions(#offer_list)

  local form_spec = {'size[', columns, ',', rows, ']'}
  insert_item_table(0, 0, columns, rows, offer_list, form_spec)
  form_spec = table.concat(form_spec)
  minetest.show_formspec(player_name, form_name, form_spec)
end

minetest.register_on_player_receive_fields(
  function(player, form_name, fields)
    if form_name ~= 'harberger_economy:buy_form' then
      return false
    end
    local player_name = player:get_player_name()
    local item_to_buy = get_item_button_pressed(fields)
    if item_to_buy then
      harberger_economy.buy(player_name, item_to_buy)
      harberger_economy.show_buy_form(player_name)
    end
    return true
  end
)

function harberger_economy.show_tax_form(player_name, rate_or_amount)
  if rate_or_amount ~= 'rate' and rate_or_amount ~= 'amount' and rate_or_amount ~= 'quantity' then
    harberger_economy.log('warning', 'Invalid rate_or_amount defaulting to amount')
    rate_or_amount = 'amount'
  end
  local form_name = 'harberger_economy:tax_form'
  local tax_by_item = harberger_economy.get_tax_per_item(player_name)
  local tax_list = {}
  for item, tax_entry in pairs(tax_by_item) do
    local label = ''
    if rate_or_amount == 'amount' then
      label = harberger_economy.round(tax_entry.total_tax)
    elseif rate_or_amount == 'rate' then
      label = string.format("%.2f", tax_entry.tax_rate * 100) .. '%'
    elseif rate_or_amount == 'quantity' then
      label = tax_entry.count
    end
    table.insert(tax_list, {item=item, label=label})
  end
  table.sort(tax_list, function (a, b) return a.item < b.item end)
  local rows, columns = get_best_dimensions(#tax_list)
  local form_spec = {'size[', columns, ',', rows, ']'}
  insert_item_table(0, 0, columns, rows, tax_list, form_spec)
  form_spec = table.concat(form_spec)
  minetest.show_formspec(player_name, form_name, form_spec)
end

function harberger_economy.show_price_form(player_name, item_name)
  if not item_name then
    item_name = ''
  end
  local form_name = 'harberger_economy:price_form'
  local offers = harberger_economy.get_reserve_offers(player_name)
  local price = (offers[item_name] or {}).price or ''
  local offer_list = {}
  for item, offer in pairs(offers) do
    table.insert(offer_list, {item=item, label=offer.price})
  end
  table.sort(offer_list, function (a, b) return a.item < b.item end)
  local rows, columns = get_best_dimensions(#offer_list, 11)
  local form_spec = {'size[', columns, ',', rows + 1, ']'}
  table.insert(form_spec, 'field[0.3,0;3,2;item_name;Item name;')
  table.insert(form_spec, item_name)
  table.insert(form_spec, ']')
  table.insert(form_spec, 'field[3.3,0;3,2;price;Price;')
  table.insert(form_spec, price)
  table.insert(form_spec, ']')
  table.insert(form_spec, 'button[6,0;2,1.3;update;Update]')
  insert_item_table(0, 1, columns, rows, offer_list, form_spec)
  form_spec = table.concat(form_spec)
  minetest.show_formspec(player_name, form_name, form_spec)
end

-- Receive price form
minetest.register_on_player_receive_fields(
  function(player, form_name, fields)
    if form_name ~= 'harberger_economy:price_form' then
      return false
    end
    local player_name = player:get_player_name()
    local item_name = fields.item_name
    local price = tonumber(fields.price)
    if fields.update or fields.key_enter_field and price then
      harberger_economy.set_reserve_price(player_name, item_name, price)
      if fields.update then
        harberger_economy.show_price_form(player_name, item_name)
      end
      return true
    end
    local new_item_name = get_item_button_pressed(fields)
    if new_item_name then
      harberger_economy.show_price_form(player_name, new_item_name)
      return true
    end
    return true
  end
)

function harberger_economy.show_region_price_form(player_name)
  local form_name = 'harberger_economy:region_price_form'
  local tax_regions = harberger_economy.get_tax_per_region(player_name)
  local region_render = {}
  for region, tax in pairs(tax_regions) do
    local price = tax.price
    local tax_rate = string.format("%.2f", tax.tax_rate * 100) .. '%'
    local total_tax = harberger_economy.round(tax.total_tax)
    table.insert(region_render, {region=region, price=price, tax_rate=tax_rate, total_tax=total_tax})
  end
  table.sort(region_render, function (a, b) return a.region < b.region end)
  local columns = 9
  local rows = #region_render
  local form_spec = {'size[', columns, ',', rows, ']'}
  for i, line in pairs(region_render) do
    local c = 0
    local r = (i - 1)
    table.insert_all(
      form_spec,
      {
        'field[', 0.2 + c, ',', r, ';3,2;', 'region_price:', line.region,
          ';Region ', line.region, ' Price;', line.price, ']',
        'button[', c + 3, ',', r + 0.15, ';2,1;', 'update:', line.region, ';Update]',
        'label[', c + 5, ',', r + 0.35, ';Tax rate: ', line.tax_rate, ']',
        'label[', c + 7, ',', r + 0.35, ';Tax total: ', line.total_tax, ']',
      }
    )
  end
  form_spec = table.concat(form_spec)
  minetest.show_formspec(player_name, form_name, form_spec)
end

-- Receive price form
minetest.register_on_player_receive_fields(
  function(player, form_name, fields)
    if form_name ~= 'harberger_economy:region_price_form' then
      return false
    end
    local player_name = player:get_player_name()
    local prefix = "update:"
    for k,v in pairs(fields) do
      if k:sub(1, #prefix) == prefix then
        local region = tonumber(k:sub(#prefix + 1, #k))
        if harberger_economy.is_region(region) then
          local price = tonumber(fields['region_price:' .. region])
          if price and price >= 0 then
            harberger_economy.set_region_price(region, price)
            harberger_economy.show_region_price_form(player_name)
          end
        end
      end
    end
  end
)

function harberger_economy.show_buy_region_form(player_name, pos)
  local form_name = 'harberger_economy:buy_region_form'
  local region = harberger_economy.get_region(pos)
  local price = harberger_economy.get_region_price(region)
  local form_spec = {
    'size[4,2]',
    'button_exit[0,0;4,1;buy:', region, ';Buy region ', region, ' for ', price, ']',
    'button_exit[0,1;4,1;cancel;Cancel]'
  }
  form_spec = table.concat(form_spec)
  minetest.show_formspec(player_name, form_name, form_spec)
end

-- Receive buy region form
minetest.register_on_player_receive_fields(
  function(player, form_name, fields)
    if form_name ~= 'harberger_economy:buy_region_form' then
      return false
    end
    local player_name = player:get_player_name()
    local prefix = "buy:"
    for k,v in pairs(fields) do
      if k:sub(1, #prefix) == prefix then
        local region = tonumber(k:sub(#prefix + 1, #k))
        if harberger_economy.is_region(region) then
          harberger_economy.buy_region(player_name, region)
        end
      end
    end
  end
)


function harberger_economy.get_owned_pos(player_name)
  return harberger_economy.with_storage(
    function (storage)
      local list = {}
      for x, a in pairs(storage.pos_to_region) do
        for y, b in pairs(a) do
          for z, region in pairs(b) do
            if region and (not player_name or storage.region_to_owner[region] == player_name) then
              table.insert(list, {x=x, y=y, z=z})
            end
          end
        end
      end
      return list
    end
  )
end

function harberger_economy.get_owned_regions(player_name)
   return harberger_economy.with_storage(
     function (storage)
       local list = {}
       for region, p in pairs(storage.region_to_owner) do
         if p == player_name then
           table.insert(list, region)
         end
       end
       return list
     end
   )
end

function harberger_economy.get_claim_on_place(player_name)
  return harberger_economy.with_storage(
    function(storage)
      return storage.claim_on_place[player_name]
    end
  )
end

function harberger_economy.set_claim_on_place(player_name, claim_on_place)
  return harberger_economy.with_storage(
    function(storage)
      storage.claim_on_place[player_name] = claim_on_place
    end
  )
end


-- END other api


-- BEGIN Useful functions

local function hide_formspec(pos)
  -- When a user right-clicks on a node with a formspec meta, a form is openned
  -- directly from C++ without going through lua. We need to override this to
  -- add protection on property. So we just hide the formspec meta and show it
  -- manually on all owned blocks.
  -- Currently bones have a formspec meta and chests do not have a formspec meta
  local meta = minetest.get_meta(pos)
  local old_formspec = meta:get("formspec")
  if old_formspec then
    meta:set_string("harberger_economy:formspec", old_formspec)
    meta:set_string("formspec", "")
  end
end

minetest.register_node("harberger_economy:test_hide_formspec", {
    description = "Test Hide formspec",
    groups = {oddly_breakable_by_hand=2},
    on_construct = function(pos)
        local meta = minetest.get_meta(pos)
        meta:set_string("formspec",
                "size[8,9]"..
                "list[current_name;main;0,0;8,4;]"..
                "list[current_player;main;0,5;8,4;]" ..
                "listring[]")
        meta:set_string("infotext", "Test Hide formspec")
        local inv = meta:get_inventory()
        inv:set_size("main", 8*4)
    end,
    on_receive_fields = function(pos, formname, fields, sender)
      sender = sender and sender:get_player_name()
      print("YO " .. dump(pos) .. " " .. dump(formname) .. " " .. dump(fields) .. " " .. dump(sender))
    end
})


function initialize_reserve_price(player_name, item_name)
  local price = harberger_economy.get_default_price(item_name)
  if harberger_economy.is_item(item_name) then
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
  return price
end

-- TODO should probably replace this function to rather do it when ever get all offer is called
local function update_reserve_prices(player, inventory)
  local player_name = player:get_player_name()
  for list_name, list in pairs(inventory:get_lists()) do
    if list_name ~= 'craftpreview' then -- ignore craftpreview since it's a 'virtual' item
      for index, item_stack in ipairs(list) do
        if not item_stack:is_empty() then
          local item_name = item_stack:get_name()
          local reserve_offer = harberger_economy.get_reserve_offer(player_name, item_name)
          if not reserve_offer then
            initialize_reserve_price(player_name, item_name)
          end
        end
        -- print(list_name .. '[' .. index  .. ']' .. " = " .. item_stack:to_string())
      end
    end
  end
end

local hud_table = {}

local function update_player_hud(player)
  local hud_ids = hud_table[player]
  if hud_ids then
    for i, hud_id in ipairs(hud_ids) do
      player:hud_remove(hud_id)
    end
  end
  hud_table[player] = {}
  local player_name = player:get_player_name()
  local balance = harberger_economy.get_balance(player_name)
  local colour = 0x00FF00
  if balance < 0 then
    colour = 0xFF0000
  end
  table.insert(
    hud_table[player],
    player:hud_add(
      {
        hud_elem_type = "text",
        position = {x = 1, y = 0},
        alignment = {x = -1, y = 1},
        offset = {x=-12, y = 6},
        number = colour,
        text = "Balance: " .. balance
      }
  ))
  local player_pos = player:get_pos()
  local eye_offset = player:get_eye_offset()
  local look_dir =  player:get_look_dir()
  -- Add look dir so we don't intersect our own eyes
  local eye_pos = vector.add(vector.add(player_pos, eye_offset), 0)
  local eye_height = player:get_properties().eye_height
  eye_pos.y = eye_pos.y + eye_height
  local end_point = vector.add(eye_pos, vector.multiply(look_dir, 5))
  local raycast = minetest.raycast(eye_pos, end_point, false)
  local pointed = raycast:next()
  if pointed then
    local under = pointed.under
    if under then
      local owner = harberger_economy.get_owner_of_pos(under)
      local region = harberger_economy.get_region(under)
      local color = 0x00FF00
      if owner ~= player_name then
        color = 0xFF0000
      end
      if owner then
        table.insert(
          hud_table[player],
          player:hud_add(
            {
              hud_elem_type = "text",
              position = {x = 1, y = 0},
              alignment = {x = -1, y = 1},
              offset = {x=-12, y = 24},
              number = color,
              text = "Block in region " .. region .. " owned by " .. owner
            }
        ))
      end
    end
  end
end

local function update_player(player)
  local player_name = player:get_player_name()
  if not harberger_economy.is_player_initialized(player_name) then
    harberger_economy.initialize_player(player)
  end
  -- can replace with
  -- minetest.register_on_player_inventory_action(
  -- function(player, action, inventory, inventory_info))
  update_persistent_inventory(player)
  update_player_hud(player)
  update_reserve_prices(player, player:get_inventory())
end

-- TODO can remove with_storage from here by creating harberger_.. methods
local function calculate_basic_income()
  return harberger_economy.with_storage(
    function(storage)
      local payout = harberger_economy.round(
        harberger_economy.config.starting_income
          * storage.time_since_last_payment
          / DAY_SECONDS * TIME_SPEED
      )
      return payout
    end
  )
end

local function give_basic_income()
  return harberger_economy.with_storage(
    function(storage)
      local payout = calculate_basic_income()
      for player, b in pairs(storage.initialized_players) do
        if b then
          harberger_economy.pay(nil, player, payout, {type='daily_income'}, true)
        end
      end
    end
  )
end

-- TODO can remove with_storage from here by creating harberger_.. methods
local function do_charges()
  return harberger_economy.with_storage(
    function(storage)
      local total_charges = 0
      for player, b in pairs(storage.initialized_players) do
        if b then
          local daily_tax_owed = harberger_economy.get_tax_owed(player)
          local payout = harberger_economy.round(
            daily_tax_owed
              * storage.time_since_last_payment
              / DAY_SECONDS * TIME_SPEED
      )
          total_charges = total_charges + payout
          harberger_economy.pay(player, nil, payout, {type='harberger_tax'}, true)
        end
      end
      return total_charges
    end
  )
end

local function do_quantity_integration()
  return harberger_economy.with_storage(
    function(storage)
      local offers = harberger_economy.get_offers()
      local dt = storage.time_since_last_payment / DAY_SECONDS * TIME_SPEED
      for item_name, offer_list in pairs(offers) do
        if not storage.quantity_days[item_name] then
          storage.quantity_days[item_name] = 0
        end
        for i, offer in ipairs(offer_list) do
          storage.quantity_days[item_name] =
            storage.quantity_days[item_name]
            + offer.count * dt
        end
      end
    end
  )
end

local function do_inflation_targeting(charges)
  local basket_price = harberger_economy.get_basket_price()
  if basket_price == 0 then
    return false
  end
  local current_supply =
    -harberger_economy.get_balance(harberger_economy.the_bank)
    + charges -- We already did the charges so add it to the current supply
  local target_price = harberger_economy.config.price_index
  local target_supply = current_supply * target_price / basket_price
  -- Prevent rapid hyper-inflation
  local days_diff = harberger_economy.get_time_since_last_payement()
    / DAY_SECONDS * TIME_SPEED
  local max_ratio = math.pow(
    harberger_economy.config.money_supply_rate_limit,
    days_diff
  )
  target_supply = math.min(target_supply, current_supply * max_ratio)
  local total_payout = target_supply - current_supply
    + charges -- We still need to pay the charges back out
  -- We don't remove money for inflation targeting, other than harberger taxes
  -- (maybe we should)
  total_payout = math.max(total_payout, 0)
  local players = harberger_economy.get_players()
  local per_player_payout = total_payout / #players
  local basic_income = calculate_basic_income()
  -- If we are dealing with small amounts of money we can ignore the max_ratio_limit
  if per_player_payout < basic_income and max_ratio <= target_supply / current_supply then
    per_player_payout = basic_income
  end
  harberger_economy.log(
    'action',
    'Inflation targeting: Price basket is ' .. basket_price
      .. " it should be " .. target_price .. '. '
      .. 'Trying to increase money supply from ' .. current_supply
      .. ' to ' .. harberger_economy.round(target_supply)
      .. ' by giving a payout of ' .. per_player_payout
      .. ' * ' .. #players
      ..' = ' .. (#players * per_player_payout)
  )
  for i, player in ipairs(players) do
    harberger_economy.pay(nil, player, per_player_payout, {type='daily_income'}, true)
  end
  return true
end

local function do_auction()
  -- When a player has a negative balance auction off their items by decreasing the prices
  local day_frac = harberger_economy.get_time_since_last_payement() / DAY_SECONDS * TIME_SPEED
  local rate = math.pow(1 - harberger_economy.config.auction_percentage/100, day_frac)
  for i, player_name in ipairs(harberger_economy.get_players()) do
    if harberger_economy.get_balance(player_name) < 0 then
      local display_rate = string.format("%.2f", (1 - rate) * 100) .. '%'
      minetest.chat_send_player(
        player_name,
        "You have a negative balance. "
          .. "Your items are being auctioned off. "
          .. "Prices of all your items have been decrease by " .. display_rate .. '.'
      )
      harberger_economy.log(
        'action',
        player_name .. ' has a negative balance.'
          .. ' Their items are being auctioned off at '
          .. display_rate .. '.'
      )
      local offers = harberger_economy.get_reserve_offers(player_name)
      for item_name, offer in pairs(offers) do
        local new_price = harberger_economy.round(offer.price * rate)
        harberger_economy.set_reserve_price(player_name, item_name, new_price)
      end
      for j, region in ipairs(harberger_economy.get_owned_regions(player_name)) do
        local old_price = harberger_economy.get_region_price(region)
        local new_price = harberger_economy.round(old_price * rate)
        harberger_economy.set_region_price(region, new_price)
      end
    end
  end
end

local function do_bankruptcy()
  -- When a player's wealth can't cover their debt seize their items and set their balance to zero
  for i, player_name in ipairs(harberger_economy.get_players()) do
    local balance = harberger_economy.get_balance(player_name)
    if balance < 0 then
      local wealth = harberger_economy.get_wealth(player_name)
      if balance + wealth < 0 then
        local message = " been declared insolvent. Repossessing and setting to zero."
        minetest.chat_send_player(player_name, 'You have' .. message)
        harberger_economy.log('action', player_name .. ' has' .. message)
        harberger_economy.pay(nil, player_name, -balance, {type='bankruptcy'}, true)
        harberger_economy.reposses_assets(player_name)
      end
    end
  end
end

local function update_owned_nodes()
  harberger_economy.with_storage(
    function (storage)
      for i, pos in ipairs(harberger_economy.get_owned_pos()) do
        hide_formspec(pos)
      end
    end
  )
end


local payment_period = DAY_SECONDS / TIME_SPEED
  / harberger_economy.config.payment_frequency

local function update_function(dtime)
  return harberger_economy.with_storage(
    function (storage)
      -- Update player inventories
      local connected_players = minetest.get_connected_players()
      for i, player in ipairs(connected_players) do
        update_player(player)
      end
      update_owned_nodes()
      -- Check if we should do payment
      storage.time_since_last_payment = storage.time_since_last_payment + dtime

      if storage.time_since_last_payment >= payment_period then
        if not too_few_players() then
          do_quantity_integration()
          local charges = do_charges()
          if not do_inflation_targeting(charges) then
            give_basic_income()
          end
          do_auction()
          do_bankruptcy()
        end
        storage.time_since_last_payment = 0
      end
    end
  )
end

-- END Useful functions

-- BEGIN Callbacks

-- TODO make sure all of these use batched storage
-- TODO profile everything, make sure everything is in O(n) time

minetest.register_privilege(
  'harberger_economy:bank_clerk',
  {
    description = "Permission to read all account balances, transaction and econometrics",
    give_to_singleplayer = false, -- this mod is pretty useless in singleplayer
    give_to_admin = true,
    on_grant = nil,
    on_revoke = nil,
  }
)

minetest.register_chatcommand(
  'harberger_economy:list_balances',
  {
    params = '',
    description = 'Lists all account balances',
    privs = {['harberger_economy:bank_clerk'] = true},
    func = function (player_name, params)
      return harberger_economy.with_storage(
        function (storage)
          local output = {}
          for user, balance in pairs(storage.balances) do
            table.insert(output, user .. ":  " .. balance)
          end
          return true, table.concat(output, "\n")
        end
      )
    end,
  }
)

minetest.register_chatcommand(
  'harberger_economy:my_balance',
  {
    params = '',
    description = 'Show me my balance',
    privs = {},
    func = function (player_name, params)
      return harberger_economy.with_storage(
        function (storage)
          return true, "Your balance is " .. storage.balances[player_name] .. "."
        end
      )
    end,
  }
)

minetest.register_chatcommand(
  'harberger_economy:buy',
  {
    params = '',
    description = 'Buy items',
    privs = {},
    func = function (player_name, params)
      harberger_economy.show_buy_form(player_name)
    end,
  }
)

minetest.register_chatcommand(
  'harberger_economy:tax',
  {
    params = '[amount (default)|rate]',
    description = 'Show tax liability',
    privs = {},
    func = function (player_name, params)
      if params ~= 'rate' and params ~= 'amount' and params ~= 'quantity' then
        params = nil
      end
      harberger_economy.show_tax_form(player_name, params)
    end,
  }
)

minetest.register_chatcommand(
  'harberger_economy:price',
  {
    params = '[item] [price]',
    description = 'Price items',
    privs = {},
    func = function (player_name, params)
      params = string.split(params, ' ')
      local item_name = params[1]
      if harberger_economy.is_item(item_name) then
        item_name = nil
      end
      local price = tonumber(params[2])
      if price and item_name then
        harberger_economy.set_reserve_price(player_name, item_name, price)
      else
        harberger_economy.show_price_form(player_name, item_name)
      end
    end
  }
)

minetest.register_chatcommand(
  'harberger_economy:region_price',
  {
    params = '[region] [price]',
    description = 'Price regions',
    privs = {},
    func = function (player_name, params)
      params = string.split(params, ' ')
      local region = params[1]
      if harberger_economy.is_region(region) then
        region = nil
      end
      local price = tonumber(params[2])
      if price and region then
        harberger_economy.set_region_price(region, price)
      else
        harberger_economy.show_region_price_form(player_name)
      end
    end
  }
)


-- minetest.register_chatcommand(
--   'harberger_economy:claim_on_place',
--   {
--     params = '(true|false)',
--     description = 'Price items',
--     privs = {},
--     func = function (player_name, params)
--       if params == 'true' then
--         harberger_economy.set_claim_on_place(player_name, true)
--         return true, "You will own all the future nodes you place"
--       elseif params == 'false' then
--         harberger_economy.set_claim_on_place(player_name, false)
--         return true, "You will NOT own all the future nodes you place"
--       else
--         return false, "Please specify 'true' or 'false' as an argument"
--       end
--     end
--   }
-- )


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

minetest.register_on_joinplayer(
  function(player)
    update_player(player)
  end
)

if sfinv then
  sfinv.register_page("harberger_economy:inventory", {
    title = "Economy",
    get = function(self, player, context)
      -- local claim_on_place = tostring(harberger_economy.get_claim_on_place(player:get_player_name()))
      return sfinv.make_formspec(
        player,
        context,
        "button[0.1,0.1;2,1;buy;Buy]"
          .. "button[0.1,1.1;2,1;price;Price]"
          .. "button[2.1,1.1;2,1;region_price;Region Price]"
          .. "button[0.1,2.1;2,1;tax_amount;Tax Amount]"
          .. "button[2.1,2.1;2,1;tax_rate;Tax Rate]"
          .. "button[4.1,2.1;2,1;item_quantity;Item Quantity]"
   --       .. "checkbox[0.1,3.1;claim_on_place;Claim on place;" .. claim_on_place .. "]"
        ,
        false
      )
    end,

    on_player_receive_fields = function(self, player, context, fields)
      local player_name = player:get_player_name()
      if fields.buy then
        harberger_economy.show_buy_form(player_name)
      elseif fields.price then
        harberger_economy.show_price_form(player_name)
      elseif fields.region_price then
        harberger_economy.show_region_price_form(player_name)
      elseif fields.tax_amount then
        harberger_economy.show_tax_form(player_name, 'amount')
      elseif fields.tax_rate then
        harberger_economy.show_tax_form(player_name, 'rate')
      elseif fields.item_quantity then
        harberger_economy.show_tax_form(player_name, 'quantity')
      -- elseif fields.claim_on_place then
      --   harberger_economy.set_claim_on_place(player_name, fields.claim_on_place == 'true')
      --   -- Update the formspec so that when we reopen it the correct default value is shown
      --   sfinv.set_page(player, "harberger_economy:inventory")
      end
    end,
  })
end

minetest.register_on_placenode(
  function (pos, newnode, placer, oldnode, itemstack, pointed_thing)
    if placer:is_player() then
      local player_name = placer:get_player_name()
      -- if harberger_economy.get_claim_on_place(player_name) then
      --   harberger_economy.disown_node(pos, oldnode)
      --   harberger_economy.claim_node(player_name, pos, newnode)
      -- end
      hide_formspec(pos)
    end
  end
)

minetest.register_on_dignode(
  function (pos, oldnode, digger)
    harberger_economy.disown_node(pos, oldnode)
  end
)

function harberger_economy.is_protected(pos, player_name)
  if harberger_economy.is_not_owner(player_name, pos) then
    return true
  end
  return false
end

local old_protected = minetest.is_protected
function minetest.is_protected(pos, player_name)
  return harberger_economy.is_protected(pos, player_name) or old_protected(pos, player_name)
end

minetest.register_on_protection_violation(
  function(pos, player_name)
    if harberger_economy.is_protected(pos, player_name) then
      local inform_players = {player_name}
      local owner = harberger_economy.get_owner_of_pos(pos)
      local region = harberger_economy.get_region(pos)
      local pos_string = minetest.pos_to_string(pos)
      table.insert(inform_players, owner)
      local message =
        player_name
        .. " tried to interact with node " .. pos_string
        .. " in region " .. region
        .. " owned by " .. owner
      harberger_economy.log_chat("warning", message, inform_players)
      harberger_economy.show_buy_region_form(player_name, pos)
    end
  end
)

function  harberger_economy.item_place_hook(itemstack, placer, pointed_thing)
  if placer and placer:get_player_name() then
    local player_name = placer:get_player_name()
    if pointed_thing and pointed_thing.above then
      if harberger_economy.is_not_owner(player_name, pointed_thing.above) then
        minetest.record_protection_violation(pointed_thing.above, player_name)
        return false, itemstack, false
      end
    end
    if pointed_thing and pointed_thing.under then
      if harberger_economy.is_not_owner(player_name, pointed_thing.under) then
        minetest.record_protection_violation(pointed_thing.under, player_name)
        return false, itemstack, false
      end
    end
  end
  return true
end

local function call_on_rightclick(itemstack, placer, pointed_thing)
  if (pointed_thing.type == "node" and placer and
      not placer:get_player_control().sneak) then
    local n = minetest.get_node(pointed_thing.under)
    local nn = n.name
    if minetest.registered_nodes[nn] and minetest.registered_nodes[nn].on_rightclick then
      return (minetest.registered_nodes[nn]
                .on_rightclick(pointed_thing.under, n, placer, itemstack, pointed_thing)
                or itemstack), false
        end
    end

end

local hide_formspec_prefix = 'haraberger_economy:hide_form_spec:'

local function emulate_formspec(itemstack, placer, pointed_thing)
  -- Try to mimic the behaviour of game.cpp:handlePointingAtNode:TheRightClickBranch
  local continue, stack, bool = harberger_economy.item_place_hook(itemstack, placer, pointed_thing)
  if not continue then
    return false, stack, bool
  end
  if pointed_thing and pointed_thing.under then
    local pos = pointed_thing.under
    local meta = minetest.get_meta(pos)
    local node_name = minetest.get_node(pos).name
    local formspec = meta:get("harberger_economy:formspec")
    local player_name = placer and placer:get_player_name()
    if formspec and player_name then
      -- Replace 'context' with absolute position
      local node_inv = 'nodemeta:' .. pos.x .. ',' .. pos.y .. ',' .. pos.z .. ';'
      formspec = formspec
        :gsub('list%[context;', 'list%[' .. node_inv)
        :gsub('list%[current_name;', 'list%[' .. node_inv)
        :gsub('listring%[context;', 'listring%[' .. node_inv)
        :gsub('listring%[current_name;', 'listring%[' .. node_inv)
      local form_name = hide_formspec_prefix
        .. node_name
        .. ":$%$:" .. minetest.pos_to_string(pos)
      minetest.show_formspec(player_name, form_name, formspec)
      return false, call_on_rightclick(itemstack, placer, pointed_thing)
    end
  end
  return true
end

local old_item_place = minetest.item_place
function minetest.item_place(itemstack, placer, pointed_thing, param2)
  local continue, stack, bool = emulate_formspec(itemstack, placer, pointed_thing)
  if not continue then
    return stack, bool
  end
  return old_item_place(itemstack, placer, pointed_thing, param2)
end

-- rotate and place node is sometines used instead of item_place so we must override that too
local old_rotate_and_place_node = minetest.rotate_and_place
function minetest.rotate_and_place(itemstack, placer, pointed_thing, infinitestacks, orient_flags, prevent_after_place)
   local continue, stack, bool = emulate_formspec(itemstack, placer, pointed_thing)
   if not continue then
     return stack, bool
   end
   return old_rotate_and_place_node(itemstack, placer, pointed_thing, infinitestacks, orient_flags, prevent_after_place)
end

minetest.register_on_player_receive_fields(
  function (player, form_name, fields)
    if form_name:sub(1, #hide_formspec_prefix) == hide_formspec_prefix then
      local info = form_name:sub(#hide_formspec_prefix + 1, #form_name)
      local node_name, pos_string = unpack(string.split(info, ":$%$:"))
      local node_spec = minetest.registered_nodes[node_name]
      if node_spec and node_spec.on_receive_fields then
        local pos = minetest.string_to_pos(pos_string)
        node_spec.on_receive_fields(pos, "", fields, player)
      end
    end
  end
)



-- END Call backs
