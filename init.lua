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
  },
  detached_inventories = {
  },
  time_since_last_payment = 0,
  daily_income = harberger_economy.config.starting_income,

}

local current_schema = '10'
local cached_storage = nil
local batch_storage = 0
function harberger_economy.get_storage()
  if batch_storage == 0 then
    local data_string = harberger_economy.storage:get('data')
    if not data_string then
      cached_storage = default_data
    else
      local data_with_schema = minetest.deserialize(data_string)
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
      end
  end)
end

function harberger_economy.is_player_initialized(player_name)
  return harberger_economy.with_storage(function (storage)
      return not not storage.initialized_players[player_name]
  end)
end

function harberger_economy.get_reserve_offers(player_name, item_name)
  return harberger_economy.with_storage(function (storage)
      return storage.reserve_offers[player_name]
  end)
end

function harberger_economy.get_reserve_offer(player_name, item_name)
  return harberger_economy.with_storage(function (storage)
      return storage.reserve_offers[player_name][item_name]
  end)
end

function harberger_economy.set_reserve_price(player_name, item_name, price)
  return harberger_economy.with_storage(function (storage)
      if not minetest.registered_items[item_name] then
        harberger_economy.log('warning', "Tried to set price of non-existent item " .. item_name .. ". Ignoring.")
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
  local cheapest_offers = harberger_economy.get_cheapest_offers()
  if cheapest_offers[item_name] then
    return cheapest_offers[item_name]
  else
      local price_index = harberger_economy.config.price_index
      local time = minetest.get_gametime()
      local time_speed =  TIME_SPEED
      return harberger_economy.round(price_index * time * time_speed / DAY_SECONDS)
  end
end

function harberger_economy.reason_to_string(reason)
  if reason.type == 'daily_income' then
    return 'Daily income'
  else
    harberger_economy.log('error', 'Reason for payment' .. reason .. ' is unknown.')
  end
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
      for player_name, b in pairs(storage.initialized_players) do
        if b and player_name ~= buying_player_name then
          local inv_list = persistent_inventory_get_items(player_name)
          for list_name, list in pairs(inv_list) do
            for index, item in ipairs(list) do
              if not item:is_empty() then
                local item_name = item:get_name()
                if not offers[item_name] then
                  offers[item_name] = {}
                end
                local offer = {}
                offer.location = {type='player', name=player_name}
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
      return offers
    end
  )
end

function harberger_economy.get_cheapest_offers(buying_player_name)
  local offers = harberger_economy.get_offers(buying_player_name)
  print("offers" .. dump(offers))
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
  print('Cheapest' .. dump(cheapest_offers))
  return cheapest_offers
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

local function update_persistent_inventory(player)
  harberger_economy.with_storage(
    function (storage)
      local player_name = player:get_player_name()
      -- BEGIN Apply changelist
      local list = storage.inventory_change_list[player_name]
      for i, a in ipairs(list) do
        -- TODO
      end
      storage.inventory_change_list[player_name] = {}
      -- END Apply changelist
      -- BEGIN Copy inventory
      local inventory_name = get_inventory_copy_name(player_name)
      local copy_inv = create_ro_detached_inventory(inventory_name)
      local player_inv = minetest.get_inventory({type="player", name=player_name})
      local serialized = {}
      for list_name, list_value in pairs(player_inv:get_lists()) do
        local width = player_inv:get_width(list_name)
        local size = player_inv:get_size(list_name)
        copy_inv:set_size(list_name, size)
        copy_inv:set_width(list_name, width)
        copy_inv:set_list(list_name, list_value)
        serialized[list_name] = {width=width, size=size}
        serialized[list_name].value = {}
        for i, item in ipairs(list_value) do
          serialized[list_name].value[i] = item:to_string()
        end
      end
      storage.detached_inventories[inventory_name] = serialized
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


-- END Persistent Inventory api

-- BEGIN other api
function harberger_economy.show_buy_form(player_name)
  local form_name = 'harberger_economy:buy_form'
  local offers = harberger_economy.get_cheapest_offers(player_name)
  local num_offers = 0  -- # only works for lists not tables
  for item, price in pairs(offers) do
    num_offers = num_offers + 1
  end
  local columns = 8
  local rows = math.ceil(num_offers/columns)

  local form_spec = {'size[', columns, ',', rows, ']'}
  local i = 0
  for item, price in pairs(offers) do
    table.insert(form_spec, 'item_image_button[')
    table.insert(form_spec, i % columns)
    table.insert(form_spec, ',')
    table.insert(form_spec, math.floor(i / columns))
    table.insert(form_spec, ';1.2,1.2;')
    table.insert(form_spec, item)
    table.insert(form_spec, ';')
    table.insert(form_spec, item)
    table.insert(form_spec, ';')
    -- if price >= 10000 then
    --   price = math.floor(price / 1000)
    --   price = price .. 'k'
    -- end

    table.insert(form_spec, price)
    table.insert(form_spec, ']')
    i = i + 1
  end
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
  local columns = 8
  local rows = math.ceil(#offer_list/columns)
  local form_spec = {'size[', columns, ',', rows + 1, ']'}
  table.insert(form_spec, 'field[0.3,0;3,2;item_name;Item name;')
  table.insert(form_spec, item_name)
  table.insert(form_spec, ']')
  table.insert(form_spec, 'field[3.3,0;3,2;price;Price;')
  table.insert(form_spec, price)
  table.insert(form_spec, ']')
  table.insert(form_spec, 'button[6,0;2,1.3;update;Update]')
  table.insert(form_spec, 'container[0, 1]')
  for i, offer in ipairs(offer_list) do
    table.insert(form_spec, 'item_image_button[')
    table.insert(form_spec, (i - 1) % columns)
    table.insert(form_spec, ',')
    table.insert(form_spec, math.floor((i - 1) / columns))
    table.insert(form_spec, ';1.1,1.1;')
    table.insert(form_spec, offer.item)
    table.insert(form_spec, ';')
    table.insert(form_spec, 'item_button:')
    table.insert(form_spec, offer.item)
    table.insert(form_spec, ';')
    table.insert(form_spec, offer.label)
    table.insert(form_spec, ']')
  end
  table.insert(form_spec, 'container_end[]')
  form_spec = table.concat(form_spec)
  print(form_spec)
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
    local prefix = "item_button:"
    for k, v in pairs(fields) do
      if k:sub(1, #prefix) == prefix then
        local new_item_name = k:sub(#prefix + 1, #k)
        harberger_economy.show_price_form(player_name, new_item_name)
        return true
      end
    end
    return true
  end
)

-- END other api


-- BEGIN Useful functions

function initialize_reserve_price(player_name, item_name)
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
  local hud_id = hud_table[player]
  if hud_id then
    player:hud_remove(hud_id)
  end
  local player_name = player:get_player_name()
  local balance = harberger_economy.get_balance(player_name)
  local colour = 0x00FF00
  if balance < 0 then
    colour = 0xFF0000
  end
  hud_table[player] = player:hud_add(
    {
      hud_elem_type = "text",
      position = {x = 1, y = 0},
      alignment = {x = -1, y = 1},
      offset = {x=-12, y = 6},
      number = colour,
      text = "Balance: " .. harberger_economy.get_balance(player_name)
    }
  )
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

local function do_payments()
  return harberger_economy.with_storage(
    function(storage)
      local payout = harberger_economy.round(
        storage.daily_income
          * storage.time_since_last_payment
          / DAY_SECONDS * TIME_SPEED
      )
      for player, b in pairs(storage.initialized_players) do
        if b then
          harberger_economy.pay(nil, player, payout, {type='daily_income'}, true)
        end
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
      -- Check if we should do payment
      storage.time_since_last_payment = storage.time_since_last_payment + dtime
      if storage.time_since_last_payment >= payment_period then
        do_payments()
        storage.time_since_last_payment = 0
      end
    end
  )
end

-- END Useful functions

-- BEGIN Callbacks

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
  'harberger_economy:price',
  {
    params = '[item] [price]',
    description = 'Price items',
    privs = {},
    func = function (player_name, params)
      params = string.split(params, ' ')
      local item_name = params[1]
      if not minetest.registered_items[item_name] then
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


-- END Call backs

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
