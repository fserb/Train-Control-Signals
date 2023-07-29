local util = require("util")

local fuel_signal = "%[virtual%-signal=refuel%-signal]"
local fuel_signal_disabled = "%[virtual%-signal=refuel%-signal%-disabled]"

local depot_signal = "%[virtual%-signal=depot%-signal]"
local depot_signal_disabled = "%[virtual%-signal=depot%-signal%-disabled]"

local skip_signal = "%[virtual%-signal=skip%-signal]"

-- space exploration support could break if se mod ever changes the name of the
-- elevator station name
local space_elevator_signal = "%[img=entity/se%-space%-elevator]"

local train_needs_refueling = function(train)
  local locomotives = train.locomotives
  for k, movers in pairs (locomotives) do
    for k, locomotive in pairs (movers) do
      local fuel_inventory = locomotive.get_fuel_inventory()
      if not fuel_inventory then return false end
      if #fuel_inventory == 0 then return false end
      fuel_inventory.sort_and_merge()
      if #fuel_inventory > 1 then
        if not fuel_inventory[2].valid_for_read then
          return true
        end
      else
        --Locomotive with only 1 fuel stack... idk, lets just guess
        local stack = fuel_inventory[1]
        if not stack.valid_for_read then
          --Nothing in the stack, needs refueling.
          return true
        end
        if stack.count < math.ceil(stack.prototype.stack_size / 4) then
          return true
        end
      end
    end
  end
  return false
end

local station_is_disabled = function(station)
  return station:find(skip_signal)
end

local station_is_control = function(station)
  return station:find(depot_signal) or station:find(fuel_signal)
end

local station_is_space_elevator = function(station)
  return station:find(space_elevator_signal)
end

local station_is_open_depot = function(station)
  if not station then return false end
  return station:find(depot_signal) and not station_is_disabled(station)
end

local train_needs_depot = function(train, old_state)

  local schedule = train.schedule
  if not schedule then return end

  if train.state == defines.train_state.wait_station then
    -- We just arrived at a station, if its a depot station keep it open
    return station_is_open_depot(schedule.records[schedule.current].station)
  end

  if old_state == defines.train_state.no_path then
    --We had no path, now we do
    --We only keep depots open if we are going to a depot
    return station_is_open_depot(schedule.records[schedule.current].station)
  end

  if old_state == defines.train_state.destination_full then
    --We had no path, now we do
    --We only keep depots open if we are going to a depot
    return station_is_open_depot(schedule.records[schedule.current].station)
  end

  if old_state == defines.train_state.wait_station then
    --We just left a station
    if train.has_path then
      --We have a path, if we're going to a depot, we keep it open.
      return station_is_open_depot(schedule.records[schedule.current].station)
    end
    return true
  end

end

local care_about =
{
  [defines.train_state.wait_station] = true,
  [defines.train_state.no_path] = true,
  [defines.train_state.destination_full] = true,
}

local on_train_changed_state = function(event)

  local train = event.train
  if not (train and train.valid) then return end

  if not (care_about[train.state] or care_about[event.old_state]) then
    -- Some state that we don't care about
    return
  end

  local schedule = train.schedule
  if not schedule then return end

  local needs_refuel = train_needs_refueling(train)
  local needs_depot = train_needs_depot(train, event.old_state)
  local changed = false
  for k, record in pairs (schedule.records) do
    local station = record.station
    if station then
      local enable = false
      local disable = false
      if station:find(fuel_signal) then
        enable = needs_refuel
        disable = not enable
      end
      if station:find(depot_signal) then
        enable = enable or needs_depot
        disable = not enable
      end
      if enable and station:find(skip_signal) then
        record.station = station:gsub(skip_signal, "")
        changed = true
      end
      if disable and not station:find(skip_signal) then
        record.station = skip_signal:gsub("%%", "") .. station
        changed = true
      end
    end
  end

  if not changed then return end

  if needs_depot then

    -- We are able to go to a depot, but we only want to do that if it is in the schedule in the correct order
    -- What that means, is we just check if the previous station in the schedule is a depot, if so, go there, if not, we stay with destination full.

    local current = schedule.current
    local index = current
    while true do
      index = index - 1
      if index == 0 then index = #schedule.records end
      if index == current then break end
      if station_is_open_depot(schedule.records[index].station) then
        schedule.current = index
        break
      end
      if not station_is_disabled(schedule.records[index].station) then
        break
      end
    end

  end

  train.schedule = schedule

end

local check_rename_signal = function(entity, old_name, enabled_name)

  local new_name = entity.backer_name

  if new_name:find(skip_signal) then
    --naughty...
    entity.backer_name = new_name:gsub(skip_signal, "")
    return
  end

  if not old_name:find(enabled_name) then
    return
  end

  --old name had a control signal, lets emulate the base game thing where it fixes the schedules

  local stops = entity.force.get_train_stops({surface = entity.surface, name = old_name})
  if next(stops) then
    --there are still some with the old name, do nothing
    return
  end

  local old_disabled_name = skip_signal:gsub("%%", "") .. old_name
  local new_disabled_name = skip_signal:gsub("%%", "") .. new_name

  local trains = entity.force.get_trains(entity.surface)

  for k, train in pairs (trains) do
    local schedule = train.schedule
    if schedule then
      local changed = false
      for k, record in pairs(schedule.records) do
        if record.station then
          if record.station == old_disabled_name then
            changed = true
            record.station = new_disabled_name
          end
        end
      end
      if changed then
        train.schedule = schedule
      end
    end
  end

end

local on_entity_renamed = function(event)
  local entity = event.entity
  if not (entity and entity.valid and entity.type == "train-stop") then
    return
  end

  check_rename_signal(entity, event.old_name, fuel_signal)
  check_rename_signal(entity, event.old_name, depot_signal)

end

local on_train_schedule_changed = function(event)
  if event.player_index then
    on_train_changed_state(event)
  end
end

-- If station after elevator is a depot/fuel station, go to a temporary station at the elevator exit
-- so that the depot/fuel enable/disable logic can be run for the newly created train.
local on_train_teleport_started_event = function(event)
  local train = event.train
  if not (train and train.valid) then return end

  local schedule = train.schedule
  if not schedule then return end

  local current = schedule.current
  local index = current
  local control_station = 0
  while true do
    index = index - 1
    if index == 0 then index = #schedule.records end
    if index == current then break end

    local station = schedule.records[index].station
    if station_is_control(station) then
      control_station = index
    elseif station_is_space_elevator(station) then
      if control_station > 0 then
        -- when using the space elevator the train is created on a curved rail inside the space elevator
        -- depending on the orientation of the elevator, the exit is either on the front or back of the current rail.
        -- to find out which one it is, we have to check each end if it is connected to another rail and if one is found,
        -- then the elevator exit is added as a temporary waypoint so that the schedule can be reevaluated by TCS
        local front_rail = train.front_rail
        for _, elevator_direction in pairs({"front", "back"}) do
          local elevator_exit = front_rail.get_rail_segment_end(defines.rail_direction[elevator_direction])
          for _, connection_direction in pairs({"straight", "left", "right"}) do
            if elevator_exit.get_connected_rail{rail_direction=defines.rail_direction.front, rail_connection_direction=defines.rail_connection_direction[connection_direction]} then
              table.insert(schedule.records, control_station, {
                rail = elevator_exit,
                temporary = true,
                wait_conditions = {{
                  type = "time",
                  compare_type = "or",
                  ticks = 1
                }}
              })
              train.schedule = schedule
              train.go_to_station(control_station)
              return
            end
          end
        end
      end
      break
    end
  end
end

local lib = {}

lib.events =
{
  [defines.events.on_train_changed_state] = on_train_changed_state,
  [defines.events.on_entity_renamed] = on_entity_renamed,
  [defines.events.on_train_schedule_changed] = on_train_schedule_changed,
}

local add_se_events = function()
  if script.active_mods["space-exploration"] then
    script.on_event(remote.call("space-exploration", "get_on_train_teleport_started_event"), on_train_teleport_started_event)
  end
end

lib.on_load = function()
  add_se_events()
end

lib.on_init = function()
  add_se_events()
end

lib.on_configuration_changed = function()
end

return lib
