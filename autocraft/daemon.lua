local Queue = require("Queue")

---@class Runtime
---@field bridge table|nil
---@field rules Rule[]
---@field rules_by_key table<string, Rule>
---@field queue Queue
---@field queued_by_key table<string, boolean>
---@field rule_state_by_key table<string, RuleState>
---@field now number
---@field reserved_cpus number
---@field min_retry_delay_ms number
---@field loop_sleep_s number

---@class Rule
---@field display_name string
---@field resource_name string
---@field fingerprint string|nil
---@field threshold_low number
---@field threshold_high number
---@field request_amount number
---@field type "item"|"fluid"
---@field enabled boolean

---@class RuleState
---@field last_attempt_ms number
---@field attempts_since_success number
---@field status "idle"|"queued"|"pending"|"crafting"|"cooldown"
---@field cooldown_until_ms number
---@field last_error string|nil
---@field last_seen_amount number|nil
---@field refill_active boolean

---@type Runtime
local runtime = {
  bridge = nil,
  rules = {},
  rules_by_key = {},
  queue = Queue:new(),
  queued_by_key = {},
  rule_state_by_key = {},
  now = os.epoch("utc"),
  reserved_cpus = 3,
  min_retry_delay_ms = 2000,
  loop_sleep_s = 1,
}

local function getBridge()
  if runtime.bridge then
    return runtime.bridge, nil
  end

  runtime.bridge = peripheral.find("meBridge")
  if not runtime.bridge then
    return nil, "ME Bridge not found"
  end

  return runtime.bridge, nil
end

---@param rule Rule
---@return string|nil
---@return string|nil
local function getRuleKey(rule)
  if rule.fingerprint and rule.fingerprint ~= "" then
    return rule.fingerprint, nil
  end

  if rule.resource_name and rule.resource_name ~= "" then
    return rule.resource_name, nil
  end

  return nil, "Rule missing fingerprint or resource_name"
end

---@param runtimeState Runtime
---@param rule Rule
---@return RuleState|nil
---@return string|nil
local function ensureRuleState(runtimeState, rule)
  local key, err = getRuleKey(rule)
  if not key then
    return nil, err
  end

  if not runtimeState.rule_state_by_key[key] then
    runtimeState.rule_state_by_key[key] = {
      last_attempt_ms = 0,
      attempts_since_success = 0,
      status = "idle",
      cooldown_until_ms = 0,
      last_error = nil,
      last_seen_amount = nil,
      refill_active = false,
    }
  end

  return runtimeState.rule_state_by_key[key], nil
end

---@param runtimeState Runtime
local function reindexRules(runtimeState)
  local validKeys = {}
  runtimeState.rules_by_key = {}

  for _, rule in ipairs(runtimeState.rules) do
    local key = getRuleKey(rule)
    if key then
      validKeys[key] = true
      runtimeState.rules_by_key[key] = rule
      ensureRuleState(runtimeState, rule)
    end
  end

  for key, _ in pairs(runtimeState.queued_by_key) do
    if not validKeys[key] then
      runtimeState.queued_by_key[key] = nil
    end
  end
end

---@param rule Rule
---@param count number|nil
---@return table
local function buildFilter(rule, count)
  if rule.fingerprint and rule.fingerprint ~= "" then
    return {
      fingerprint = rule.fingerprint,
      count = count,
    }
  end

  return {
    name = rule.resource_name,
    count = count,
  }
end

---@param bridge table
---@param rule Rule
---@return number|nil
---@return string|nil
local function getStoredAmount(bridge, rule)
  local filter = buildFilter(rule, nil)
  local result

  if rule.type == "fluid" then
    result = bridge.getFluid(filter)
  else
    result = bridge.getItem(filter)
  end

  if result == nil then
    return 0, nil
  end

  return result.amount or 0, nil
end

---@param bridge table
---@return table|nil
---@return string|nil
local function getCpuInfo(bridge)
  local cpus, err = bridge.getCraftingCPUs()
  if not cpus then
    return nil, err or "Failed to get crafting CPUs"
  end

  local info = {
    list = cpus,
    total = #cpus,
    free = 0,
    busy = 0,
  }

  for _, cpu in ipairs(cpus) do
    if cpu.isBusy then
      info.busy = info.busy + 1
    else
      info.free = info.free + 1
    end
  end

  return info, nil
end

---@param bridge table
---@param rule Rule
---@param state RuleState
---@param now number
---@return boolean
local function shouldQueue(bridge, rule, state, now)
  if not rule.enabled then
    return false
  end

  if state.status == "queued" or state.status == "pending" or state.status == "crafting" then
    return false
  end

  if state.status == "cooldown" and now < state.cooldown_until_ms then
    return false
  end

  local amount = getStoredAmount(bridge, rule)
  if amount == nil then
    return false
  end

  state.last_seen_amount = amount

  if amount <= rule.threshold_low then
    state.refill_active = true
  elseif amount >= rule.threshold_high then
    state.refill_active = false
  end

  return state.refill_active == true
end

---@param filename string
---@return Rule[]|nil
---@return string|nil
local function loadRulesFromFile(filename)
  if not fs.exists(filename) then
    return {}, nil
  end

  local f = fs.open(filename, "r")
  if not f then
    return nil, "Failed to open rules file"
  end

  local text = f.readAll()
  f.close()

  local rules = textutils.unserialize(text)
  if type(rules) ~= "table" then
    return nil, "Invalid rules file"
  end

  for i, rule in ipairs(rules) do
    if not rule.fingerprint and not rule.resource_name then
      return nil, "Rule #" .. i .. " missing fingerprint or resource_name"
    end

    if type(rule.threshold_low) ~= "number" then
      return nil, "Rule #" .. i .. " missing threshold_low"
    end

    if type(rule.threshold_high) ~= "number" then
      return nil, "Rule #" .. i .. " missing threshold_high"
    end

    if type(rule.request_amount) ~= "number" then
      return nil, "Rule #" .. i .. " missing request_amount"
    end

    if rule.type ~= "item" and rule.type ~= "fluid" then
      return nil, "Rule #" .. i .. " invalid type"
    end

    rule.enabled = rule.enabled ~= false
  end

  return rules, nil
end

---@param rule Rule
---@return boolean
---@return string|nil
local function enqueue(rule)
  local key, err = getRuleKey(rule)
  if not key then
    return false, err
  end

  local state = runtime.rule_state_by_key[key]
  if not state then
    return false, "Missing rule state"
  end

  if runtime.queued_by_key[key] then
    return false, "Already queued"
  end

  if state.status == "pending" or state.status == "crafting" then
    return false, "Already processing"
  end

  runtime.queue:enqueue(key)
  runtime.queued_by_key[key] = true
  state.status = "queued"
  state.last_error = nil

  return true, nil
end

---@param bridge table
---@param rule Rule
---@return boolean|nil
---@return string|nil
local function startCraft(bridge, rule)
  local request = buildFilter(rule, rule.request_amount)

  if rule.type == "fluid" then
    if type(bridge.craftFluid) ~= "function" then
      return nil, "Bridge does not support craftFluid"
    end
    return bridge.craftFluid(request)
  end

  if type(bridge.craftItem) ~= "function" then
    return nil, "Bridge does not support craftItem"
  end

  return bridge.craftItem(request)
end

---@param state RuleState
---@param now number
local function markCooldown(state, now)
  local delay = runtime.min_retry_delay_ms * math.max(1, state.attempts_since_success)
  state.status = "cooldown"
  state.cooldown_until_ms = now + delay
end

---@param bridge table
---@param rule Rule
---@return boolean
local function isBridgeProcessing(bridge, rule)
  local filter = buildFilter(rule, nil)

  if rule.type == "fluid" then
    if type(bridge.isFluidCrafting) == "function" then
      local ok = bridge.isFluidCrafting(filter)
      return ok == true
    end

    if type(bridge.isItemCrafting) == "function" then
      local ok = bridge.isItemCrafting(filter)
      return ok == true
    end

    return false
  end

  if type(bridge.isItemCrafting) ~= "function" then
    return false
  end

  local ok = bridge.isItemCrafting(filter)
  return ok == true
end

---@param bridge table
---@param rule Rule
---@param state RuleState
---@return boolean
local function isFastCraftCompleted(bridge, rule, state)
  local currentAmount = getStoredAmount(bridge, rule)
  if currentAmount == nil then
    return false
  end

  local previousAmount = state.last_seen_amount
  state.last_seen_amount = currentAmount

  if previousAmount == nil then
    return false
  end

  return currentAmount > previousAmount
end

---@param bridge table
---@param rule Rule
---@param state RuleState
---@return boolean processing
---@return boolean completedFast
local function isProcessing(bridge, rule, state)
  if isBridgeProcessing(bridge, rule) then
    return true, false
  end

  if isFastCraftCompleted(bridge, rule, state) then
    return false, true
  end

  return false, false
end

---@return boolean
---@return string|nil
local function processNextCraft()
  local bridge, bridgeErr = getBridge()
  if not bridge then
    return false, bridgeErr
  end

  local cpuInfo, cpuErr = getCpuInfo(bridge)
  if not cpuInfo then
    return false, cpuErr
  end

  if cpuInfo.free <= runtime.reserved_cpus then
    return false, "No craftable CPUs available after reserve"
  end

  local key = runtime.queue:peek()
  if not key then
    return false, "Queue empty"
  end

  local rule = runtime.rules_by_key[key]
  if not rule then
    runtime.queue:dequeue()
    runtime.queued_by_key[key] = nil
    return false, "Queued rule missing"
  end

  local state = runtime.rule_state_by_key[key]
  if not state then
    runtime.queue:dequeue()
    runtime.queued_by_key[key] = nil
    return false, "Queued rule state missing"
  end

  runtime.now = os.epoch("utc")

  local beforeAmount = getStoredAmount(bridge, rule)
  state.last_seen_amount = beforeAmount or state.last_seen_amount
  state.last_attempt_ms = runtime.now
  state.status = "pending"
  state.last_error = nil

  local ok, craftErr = startCraft(bridge, rule)
  if not ok then
    runtime.queue:dequeue()
    runtime.queued_by_key[key] = nil

    state.attempts_since_success = state.attempts_since_success + 1
    state.last_error = craftErr or "Craft request rejected"
    markCooldown(state, runtime.now)

    return false, state.last_error
  end

  sleep(0.5)

  local processing, completedFast = isProcessing(bridge, rule, state)

  runtime.queue:dequeue()
  runtime.queued_by_key[key] = nil

  if processing then
    state.status = "crafting"
    state.attempts_since_success = 0
    state.cooldown_until_ms = 0
    state.last_error = nil
    return true, nil
  end

  if completedFast then
    local amount = getStoredAmount(bridge, rule)
    if amount ~= nil then
      state.last_seen_amount = amount
      if amount >= rule.threshold_high then
        state.refill_active = false
      end
    end

    state.status = "idle"
    state.attempts_since_success = 0
    state.cooldown_until_ms = 0
    state.last_error = nil
    return true, nil
  end

  state.attempts_since_success = state.attempts_since_success + 1
  state.last_error = "Craft start could not be confirmed"
  markCooldown(state, runtime.now)
  enqueue(rule)

  return false, state.last_error
end

---@param bridge table
local function refreshCraftingStates(bridge)
  for _, rule in ipairs(runtime.rules) do
    local key = getRuleKey(rule)
    if key then
      local state = runtime.rule_state_by_key[key]
      if state then
        local amount = getStoredAmount(bridge, rule)

        if state.status == "cooldown" then
          if runtime.now >= state.cooldown_until_ms then
            state.status = "idle"
            state.last_error = nil
          end
        elseif state.status == "pending" or state.status == "crafting" then
          local processing, completedFast = isProcessing(bridge, rule, state)

          if processing then
            state.status = "crafting"
            state.last_error = nil
          elseif completedFast then
            local newAmount = state.last_seen_amount

            if newAmount ~= nil then
              if newAmount <= rule.threshold_low then
                state.refill_active = true
              elseif newAmount >= rule.threshold_high then
                state.refill_active = false
              end
            end

            state.status = "idle"
            state.attempts_since_success = 0
            state.cooldown_until_ms = 0
            state.last_error = nil
          elseif state.status == "pending" and (runtime.now - state.last_attempt_ms) > 3000 then
            state.attempts_since_success = state.attempts_since_success + 1
            state.last_error = "Craft did not appear to start"
            markCooldown(state, runtime.now)
          end
        else
          if amount ~= nil then
            state.last_seen_amount = amount

            if amount <= rule.threshold_low then
              state.refill_active = true
            elseif amount >= rule.threshold_high then
              state.refill_active = false
            end
          end
        end
      end
    end
  end
end

local rules, err = loadRulesFromFile("rules.db")
if not rules then
  error("Failed to load rules: " .. tostring(err), 0)
end

runtime.rules = rules
reindexRules(runtime)

local function daemon()
  while true do
    runtime.now = os.epoch("utc")

    local bridge = getBridge()
    if bridge then
      refreshCraftingStates(bridge)

      for _, rule in ipairs(runtime.rules) do
        local key = getRuleKey(rule)
        if key then
          local state = runtime.rule_state_by_key[key]
          if state and shouldQueue(bridge, rule, state, runtime.now) then
            enqueue(rule)
          end
        end
      end

      processNextCraft()
    end

    sleep(runtime.loop_sleep_s)
  end
end

return {
  daemon = daemon,
  runtime = runtime,
  getBridge = getBridge,
  getCpuInfo = getCpuInfo,
  getRuleKey = getRuleKey,
  ensureRuleState = ensureRuleState,
  loadRulesFromFile = loadRulesFromFile,
  enqueue = enqueue,
  processNextCraft = processNextCraft,
  isProcessing = isProcessing,
  reindexRules = reindexRules,
}
