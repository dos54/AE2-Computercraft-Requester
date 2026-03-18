local daemonMod = require("daemon")

local UI = {}

local RULES_FILE = "rules.db"

---@class Rule
---@field display_name string
---@field resource_name string
---@field fingerprint string|nil
---@field threshold_low number
---@field threshold_high number
---@field request_amount number
---@field type "item"|"fluid"
---@field enabled boolean

local state = {
  screen = "main", ---@type "main"|"add_list"|"edit_list"|"rule_actions"|"form"|"view_requests"
  selected = 1,
  scroll = 0,
  message = "",
  running = true,

  list = {},
  menu = {},

  activeRule = nil,
  formMode = nil,
  formSelected = 1,
  formFields = {},
  formSource = nil,

  actionSelected = 1,
}

local function clamp(n, min, max)
  if n < min then return min end
  if n > max then return max end
  return n
end

local function clear()
  term.setBackgroundColor(colors.black)
  term.setTextColor(colors.white)
  term.clear()
  term.setCursorPos(1, 1)
end

local function writeAt(x, y, text, fg, bg)
  term.setCursorPos(x, y)
  term.setTextColor(fg or colors.white)
  term.setBackgroundColor(bg or colors.black)
  term.write(text)
end

local function fillLine(y, bg)
  local w = term.getSize()
  writeAt(1, y, string.rep(" ", w), colors.white, bg or colors.black)
end

local function ellipsize(s, maxLen)
  s = tostring(s or "")
  if #s <= maxLen then return s end
  if maxLen <= 3 then return s:sub(1, maxLen) end
  return s:sub(1, maxLen - 3) .. "..."
end

local function loadRules()
  if not fs.exists(RULES_FILE) then
    return {}, nil
  end

  local f = fs.open(RULES_FILE, "r")
  if not f then
    return nil, "Failed to open rules file"
  end

  local text = f.readAll()
  f.close()

  local data = textutils.unserialize(text)
  if type(data) ~= "table" then
    return nil, "Invalid rules file"
  end

  return data, nil
end

local function saveRules(rules)
  local f = fs.open(RULES_FILE, "w")
  if not f then
    return false, "Failed to write rules file"
  end

  f.write(textutils.serialize(rules))
  f.close()
  return true, nil
end

local function ruleKey(rule)
  if rule.fingerprint and rule.fingerprint ~= "" then
    return rule.fingerprint
  end
  return rule.resource_name
end

local function sameRule(a, b)
  return ruleKey(a) == ruleKey(b)
end

local function syncRuntimeRules()
  local rules = loadRules()
  if type(rules) == "table" then
    daemonMod.runtime.rules = rules
    if daemonMod.reindexRules then
      daemonMod.reindexRules(daemonMod.runtime)
    end
  end
end

local function getRulesOrEmpty()
  return daemonMod.runtime.rules or {}
end

local function getBridge()
  if daemonMod.getBridge then
    local bridge = daemonMod.getBridge()
    if type(bridge) == "table" then
      return bridge
    end
  end
  return peripheral.find("meBridge")
end

local function existingRuleKeySet()
  local out = {}
  for _, rule in ipairs(getRulesOrEmpty()) do
    out[ruleKey(rule)] = true
  end
  return out
end

local function makeRuleFromCraftable(item, kind)
  return {
    display_name = item.displayName or item.name,
    resource_name = item.name,
    fingerprint = item.fingerprint,
    threshold_low = 0,
    threshold_high = 0,
    request_amount = 1,
    type = kind,
    enabled = true,
  }
end

local function buildAddList()
  local bridge = getBridge()
  if not bridge then
    state.message = "Bridge not found"
    return {}
  end

  local exclude = existingRuleKeySet()
  local out = {}

  if type(bridge.listCraftableItems) == "function" then
    local items = bridge.listCraftableItems()
    if type(items) == "table" then
      for _, item in ipairs(items) do
        local rule = makeRuleFromCraftable(item, "item")
        if not exclude[ruleKey(rule)] then
          out[#out + 1] = { label = rule.display_name or rule.resource_name, value = rule }
        end
      end
    end
  end

  if type(bridge.listCraftableFluid) == "function" then
    local fluids = bridge.listCraftableFluid()
    if type(fluids) == "table" then
      for _, item in ipairs(fluids) do
        local rule = makeRuleFromCraftable(item, "fluid")
        if not exclude[ruleKey(rule)] then
          out[#out + 1] = { label = rule.display_name or rule.resource_name, value = rule }
        end
      end
    end
  end

  table.sort(out, function(a, b)
    return a.label:lower() < b.label:lower()
  end)

  return out
end

local function buildEditList()
  local out = {}
  for _, rule in ipairs(getRulesOrEmpty()) do
    out[#out + 1] = { value = rule }
  end

  table.sort(out, function(a, b)
    return (a.value.display_name or a.value.resource_name):lower() <
        (b.value.display_name or b.value.resource_name):lower()
  end)

  return out
end

local function statusPriority(status)
  if status == "crafting" then return 1 end
  if status == "queued" or status == "pending" or status == "cooldown" then return 2 end
  return 3
end

local function buildViewList()
  local out = {}

  for _, rule in ipairs(getRulesOrEmpty()) do
    local key = ruleKey(rule)
    local rs = daemonMod.runtime.rule_state_by_key[key]
    out[#out + 1] = {
      rule = rule,
      state = rs,
    }
  end

  table.sort(out, function(a, b)
    local sa = a.state and a.state.status or "idle"
    local sb = b.state and b.state.status or "idle"

    local pa = statusPriority(sa)
    local pb = statusPriority(sb)

    if pa ~= pb then
      return pa < pb
    end

    local na = a.rule.display_name or a.rule.resource_name
    local nb = b.rule.display_name or b.rule.resource_name
    return na:lower() < nb:lower()
  end)

  return out
end

local function setScreenMain()
  state.screen = "main"
  state.selected = 1
  state.scroll = 0
  state.menu = {
    {
      label = "Add Request",
      action = function()
        state.list = buildAddList()
        state.screen = "add_list"
        state.selected = 1
        state.scroll = 0
      end
    },
    {
      label = "Edit Request",
      action = function()
        state.list = buildEditList()
        state.screen = "edit_list"
        state.selected = 1
        state.scroll = 0
      end
    },
    {
      label = "View Requests",
      action = function()
        state.list = buildViewList()
        state.screen = "view_requests"
        state.selected = 1
        state.scroll = 0
      end
    },
    {
      label = "Refresh",
      action = function()
        syncRuntimeRules()
        state.message = "Refreshed"
      end
    },
    {
      label = "Quit",
      action = function()
        state.running = false
      end
    },
  }
end

local function openForm(sourceRule, mode)
  state.screen = "form"
  state.formMode = mode
  state.formSelected = 1
  state.formSource = sourceRule
  state.formFields = {
    { key = "threshold_low",  label = "Low Threshold",  value = tostring(sourceRule.threshold_low or 0),  numeric = true },
    { key = "threshold_high", label = "High Threshold", value = tostring(sourceRule.threshold_high or 0), numeric = true },
    { key = "request_amount", label = "Batch Amount",   value = tostring(sourceRule.request_amount or 1), numeric = true },
  }
end

local function openRuleActions(rule)
  state.activeRule = rule
  state.screen = "rule_actions"
  state.actionSelected = 1
end

local function validateForm()
  local low = tonumber(state.formFields[1].value)
  local high = tonumber(state.formFields[2].value)
  local amount = tonumber(state.formFields[3].value)

  if not low or low < 0 then
    state.message = "Invalid low threshold"
    return false
  end
  if not high or high < 0 then
    state.message = "Invalid high threshold"
    return false
  end
  if high < low then
    state.message = "High must be >= low"
    return false
  end
  if not amount or amount <= 0 then
    state.message = "Invalid batch amount"
    return false
  end

  return true
end

local function saveForm()
  if not validateForm() then
    return
  end

  local rules, err = loadRules()
  if not rules then
    state.message = err or "Failed to load rules"
    return
  end

  local src = state.formSource
  if not src then
    state.message = "Missing form source"
    return
  end

  src.threshold_low = tonumber(state.formFields[1].value)
  src.threshold_high = tonumber(state.formFields[2].value)
  src.request_amount = tonumber(state.formFields[3].value)
  src.enabled = src.enabled ~= false

  if state.formMode == "add" then
    rules[#rules + 1] = src
  else
    for i, rule in ipairs(rules) do
      if sameRule(rule, src) then
        rules[i] = src
        break
      end
    end
  end

  local ok, saveErr = saveRules(rules)
  if not ok then
    state.message = saveErr or "Failed to save"
    return
  end

  syncRuntimeRules()
  state.message = state.formMode == "add" and "Rule added" or "Rule updated"

  if state.formMode == "add" then
    state.list = buildAddList()
    state.screen = "add_list"
  else
    state.list = buildEditList()
    state.screen = "edit_list"
  end
end

local function removeActiveRule()
  local active = state.activeRule
  if not active then
    state.message = "No active rule"
    return
  end

  local rules, err = loadRules()
  if not rules then
    state.message = err or "Failed to load rules"
    return
  end

  local out = {}
  for _, rule in ipairs(rules) do
    if not sameRule(rule, active) then
      out[#out + 1] = rule
    end
  end

  local ok, saveErr = saveRules(out)
  if not ok then
    state.message = saveErr or "Failed to save rules"
    return
  end

  syncRuntimeRules()
  state.message = "Rule removed"
  state.list = buildEditList()
  state.screen = "edit_list"
  state.selected = 1
  state.scroll = 0
end

local function ensureVisible(total, selected, scroll, visibleRows)
  if total <= 0 then
    return 0
  end

  if selected <= scroll then
    scroll = selected - 1
  elseif selected > scroll + visibleRows then
    scroll = selected - visibleRows
  end

  if scroll < 0 then scroll = 0 end
  return scroll
end

local function drawHeader(title)
  local w = term.getSize()
  fillLine(1, colors.blue)
  writeAt(2, 1, ellipsize(title, w - 2), colors.white, colors.blue)
end

local function drawNavBar()
  local w, h = term.getSize()
  fillLine(h, colors.gray)

  local buttons = {}
  if state.screen == "main" then
    buttons = {
      { label = "[Select]", x1 = 2 },
      { label = "[Quit]",   x1 = 13 },
    }
  elseif state.screen == "form" then
    buttons = {
      { label = "[Save]", x1 = 2 },
      { label = "[Back]", x1 = 11 },
    }
  elseif state.screen == "rule_actions" then
    buttons = {
      { label = "[Select]", x1 = 2 },
      { label = "[Back]",   x1 = 13 },
    }
  else
    buttons = {
      { label = "[Select]", x1 = 2 },
      { label = "[Back]",   x1 = 13 },
      { label = "[Main]",   x1 = 22 },
    }
  end

  for _, btn in ipairs(buttons) do
    writeAt(btn.x1, h, btn.label, colors.black, colors.gray)
    btn.x2 = btn.x1 + #btn.label - 1
  end

  local msg = state.message ~= "" and state.message or ""
  if msg ~= "" then
    writeAt(32, h, ellipsize(msg, w - 32), colors.black, colors.gray)
  end

  return buttons
end

local function drawMain()
  clear()
  drawHeader("AutoCraft - Main Menu")

  local _, h = term.getSize()
  local startY = 3
  local visibleRows = h - 4

  state.scroll = ensureVisible(#state.menu, state.selected, state.scroll, visibleRows)

  for i = 1, visibleRows do
    local idx = state.scroll + i
    local y = startY + i - 1
    fillLine(y)

    local item = state.menu[idx]
    if item then
      local bg = idx == state.selected and colors.lightGray or colors.black
      local fg = idx == state.selected and colors.black or colors.white
      writeAt(3, y, item.label, fg, bg)
    end
  end

  drawNavBar()
end

local function drawAddList()
  clear()
  drawHeader("Add Request")

  local w, h = term.getSize()
  local startY = 3
  local visibleRows = h - 4

  state.scroll = ensureVisible(#state.list, state.selected, state.scroll, visibleRows)

  if #state.list == 0 then
    writeAt(3, 4, "No craftable items available", colors.lightGray)
  end

  for i = 1, visibleRows do
    local idx = state.scroll + i
    local y = startY + i - 1
    fillLine(y)

    local item = state.list[idx]
    if item then
      local bg = idx == state.selected and colors.lightGray or colors.black
      local fg = idx == state.selected and colors.black or colors.white
      writeAt(2, y, ellipsize(item.label, w - 2), fg, bg)
    end
  end

  drawNavBar()
end

local function drawEditList()
  clear()
  drawHeader("Edit Request")

  local w, h = term.getSize()
  local startY = 3
  local visibleRows = h - 4
  local rowsPerItem = 2
  local visibleItems = math.max(1, math.floor(visibleRows / rowsPerItem))

  state.scroll = ensureVisible(#state.list, state.selected, state.scroll, visibleItems)

  if #state.list == 0 then
    writeAt(3, 4, "No rules added", colors.lightGray)
  end

  for i = 1, visibleItems do
    local idx = state.scroll + i
    local y = startY + (i - 1) * 2
    fillLine(y)
    fillLine(y + 1)

    local entry = state.list[idx]
    if entry then
      local rule = entry.value
      local selected = idx == state.selected
      local bg = selected and colors.lightGray or colors.black
      local fg = selected and colors.black or colors.white

      writeAt(2, y, ellipsize(rule.display_name or rule.resource_name, w - 2), fg, bg)
      local info = string.format(
        "low:%d  high:%d  batch:%d  %s",
        rule.threshold_low,
        rule.threshold_high,
        rule.request_amount,
        rule.type
      )
      writeAt(4, y + 1, ellipsize(info, w - 4), fg, bg)
    end
  end

  drawNavBar()
end

local function drawViewRequests()
  clear()
  drawHeader("View Requests")

  state.list = buildViewList()

  local w, h = term.getSize()
  local startY = 3
  local visibleRows = h - 4
  local rowsPerItem = 2
  local visibleItems = math.max(1, math.floor(visibleRows / rowsPerItem))

  state.scroll = ensureVisible(#state.list, state.selected, state.scroll, visibleItems)

  if #state.list == 0 then
    writeAt(3, 4, "No rules added", colors.lightGray)
  end

  for i = 1, visibleItems do
    local idx = state.scroll + i
    local y = startY + (i - 1) * 2
    fillLine(y)
    fillLine(y + 1)

    local entry = state.list[idx]
    if entry then
      local rule = entry.rule
      local rs = entry.state
      local selected = idx == state.selected
      local bg = selected and colors.lightGray or colors.black
      local fg = selected and colors.black or colors.white
      local status = rs and rs.status or "idle"

      writeAt(2, y, ellipsize((rule.display_name or rule.resource_name) .. " [" .. status .. "]", w - 2), fg, bg)

      local amount = rs and rs.last_seen_amount or 0
      local info = string.format(
        "amt:%d  low:%d  high:%d  batch:%d  refill:%s",
        amount or 0,
        rule.threshold_low,
        rule.threshold_high,
        rule.request_amount,
        (rs and rs.refill_active) and "yes" or "no"
      )
      writeAt(4, y + 1, ellipsize(info, w - 4), fg, bg)
    end
  end

  drawNavBar()
end

local function drawRuleActions()
  clear()
  drawHeader("Rule Actions")

  local rule = state.activeRule
  if not rule then
    writeAt(3, 4, "No rule selected", colors.red)
    drawNavBar()
    return
  end

  writeAt(3, 3, rule.display_name or rule.resource_name)
  writeAt(3, 4, "low: " .. tostring(rule.threshold_low))
  writeAt(3, 5, "high: " .. tostring(rule.threshold_high))
  writeAt(3, 6, "batch: " .. tostring(rule.request_amount))
  writeAt(3, 7, "type: " .. tostring(rule.type))

  local options = { "Edit", "Remove", "Back" }
  for i, label in ipairs(options) do
    local y = 9 + i
    local bg = i == state.actionSelected and colors.lightGray or colors.black
    local fg = i == state.actionSelected and colors.black or colors.white
    writeAt(4, y, label, fg, bg)
  end

  drawNavBar()
end

local function drawForm()
  clear()
  drawHeader(state.formMode == "add" and "Add Request" or "Edit Request")

  local src = state.formSource
  if src then
    writeAt(3, 3, ellipsize(src.display_name or src.resource_name, 48))
    writeAt(3, 4, ellipsize(src.resource_name, 48), colors.lightGray)
  end

  for i, field in ipairs(state.formFields) do
    local y = 6 + (i - 1) * 2
    writeAt(3, y, field.label .. ":")
    local bg = i == state.formSelected and colors.lightGray or colors.black
    local fg = i == state.formSelected and colors.black or colors.white
    writeAt(20, y, string.rep(" ", 16), fg, bg)
    writeAt(20, y, ellipsize(field.value, 16), fg, bg)
  end

  local saveIndex = #state.formFields + 1
  local backIndex = #state.formFields + 2

  writeAt(3, 14, "[ Save ]", state.formSelected == saveIndex and colors.black or colors.white,
    state.formSelected == saveIndex and colors.lightGray or colors.black)
  writeAt(15, 14, "[ Back ]", state.formSelected == backIndex and colors.black or colors.white,
    state.formSelected == backIndex and colors.lightGray or colors.black)

  drawNavBar()
end

local function redraw()
  if state.screen == "main" then
    drawMain()
  elseif state.screen == "add_list" then
    drawAddList()
  elseif state.screen == "edit_list" then
    drawEditList()
  elseif state.screen == "view_requests" then
    drawViewRequests()
  elseif state.screen == "rule_actions" then
    drawRuleActions()
  elseif state.screen == "form" then
    drawForm()
  end
end

local function goBack()
  if state.screen == "main" then
    return
  elseif state.screen == "add_list" or state.screen == "edit_list" or state.screen == "view_requests" then
    setScreenMain()
  elseif state.screen == "rule_actions" then
    state.screen = "edit_list"
  elseif state.screen == "form" then
    if state.formMode == "add" then
      state.screen = "add_list"
    else
      state.screen = "edit_list"
    end
  end
end

local function moveSelection(delta, maxCount, visibleCount)
  if maxCount <= 0 then
    state.selected = 1
    state.scroll = 0
    return
  end

  state.selected = clamp(state.selected + delta, 1, maxCount)
  state.scroll = ensureVisible(maxCount, state.selected, state.scroll, visibleCount)
end

local function activateCurrent()
  if state.screen == "main" then
    local item = state.menu[state.selected]
    if item and item.action then item.action() end
    return
  end

  if state.screen == "add_list" then
    local item = state.list[state.selected]
    if not item then return end

    local rule = item.value
    openForm({
      display_name = rule.display_name,
      resource_name = rule.resource_name,
      fingerprint = rule.fingerprint,
      threshold_low = 0,
      threshold_high = 0,
      request_amount = 1,
      type = rule.type,
      enabled = true,
    }, "add")
    return
  end

  if state.screen == "edit_list" then
    local item = state.list[state.selected]
    if item then
      openRuleActions(item.value)
    end
    return
  end

  if state.screen == "rule_actions" then
    if state.actionSelected == 1 then
      local r = state.activeRule
      if r then
        openForm({
          display_name = r.display_name,
          resource_name = r.resource_name,
          fingerprint = r.fingerprint,
          threshold_low = r.threshold_low,
          threshold_high = r.threshold_high,
          request_amount = r.request_amount,
          type = r.type,
          enabled = r.enabled,
        }, "edit")
      end
    elseif state.actionSelected == 2 then
      removeActiveRule()
    else
      goBack()
    end
    return
  end

  if state.screen == "form" then
    local saveIndex = #state.formFields + 1
    local backIndex = #state.formFields + 2

    if state.formSelected == saveIndex then
      saveForm()
    elseif state.formSelected == backIndex then
      goBack()
    end
  end
end

local function handleKey(key)
  local _, h = term.getSize()

  if state.screen == "main" then
    local visibleRows = h - 4
    if key == keys.up then
      moveSelection(-1, #state.menu, visibleRows)
    elseif key == keys.down then
      moveSelection(1, #state.menu, visibleRows)
    elseif key == keys.enter then
      activateCurrent()
    elseif key == keys.q then
      state.running = false
    end
    return
  end

  if state.screen == "add_list" then
    local visibleRows = h - 4
    if key == keys.up then
      moveSelection(-1, #state.list, visibleRows)
    elseif key == keys.down then
      moveSelection(1, #state.list, visibleRows)
    elseif key == keys.enter then
      activateCurrent()
    elseif key == keys.backspace then
      goBack()
    end
    return
  end

  if state.screen == "edit_list" or state.screen == "view_requests" then
    local visibleItems = math.max(1, math.floor((h - 4) / 2))
    if key == keys.up then
      moveSelection(-1, #state.list, visibleItems)
    elseif key == keys.down then
      moveSelection(1, #state.list, visibleItems)
    elseif key == keys.enter and state.screen == "edit_list" then
      activateCurrent()
    elseif key == keys.backspace then
      goBack()
    end
    return
  end

  if state.screen == "rule_actions" then
    if key == keys.up then
      state.actionSelected = clamp(state.actionSelected - 1, 1, 3)
    elseif key == keys.down then
      state.actionSelected = clamp(state.actionSelected + 1, 1, 3)
    elseif key == keys.enter then
      activateCurrent()
    elseif key == keys.backspace then
      goBack()
    end
    return
  end

  if state.screen == "form" then
    local maxIndex = #state.formFields + 2

    if key == keys.up then
      state.formSelected = clamp(state.formSelected - 1, 1, maxIndex)
    elseif key == keys.down then
      state.formSelected = clamp(state.formSelected + 1, 1, maxIndex)
    elseif key == keys.left and state.formSelected > #state.formFields then
      state.formSelected = clamp(state.formSelected - 1, 1, maxIndex)
    elseif key == keys.right and state.formSelected >= #state.formFields then
      state.formSelected = clamp(state.formSelected + 1, 1, maxIndex)
    elseif key == keys.backspace then
      if state.formSelected <= #state.formFields then
        local field = state.formFields[state.formSelected]
        field.value = field.value:sub(1, -2)
      else
        goBack()
      end
    elseif key == keys.enter then
      activateCurrent()
    end
  end
end

local function handleChar(ch)
  if state.screen ~= "form" then return end
  if state.formSelected > #state.formFields then return end

  local field = state.formFields[state.formSelected]
  if field.numeric and not ch:match("%d") then return end
  field.value = field.value .. ch
end

local function handleMouseClick(button, x, y)
  if button ~= 1 then return end

  local _, h = term.getSize()

  if y == h then
    if x >= 2 and x <= 9 then
      activateCurrent()
      return
    elseif x >= 11 and x <= 16 then
      goBack()
      return
    elseif x >= 22 and x <= 27 then
      setScreenMain()
      return
    end
  end

  if state.screen == "main" then
    local row = y - 2
    if row >= 1 and row <= #state.menu then
      state.selected = row
      activateCurrent()
    end
    return
  end

  if state.screen == "add_list" then
    local row = y - 2
    local _, hh = term.getSize()
    local visibleRows = hh - 4
    if row >= 1 and row <= visibleRows then
      local idx = state.scroll + row
      if idx >= 1 and idx <= #state.list then
        state.selected = idx
        activateCurrent()
      end
    end
    return
  end

  if state.screen == "edit_list" or state.screen == "view_requests" then
    local itemRow = math.floor((y - 3) / 2) + 1
    local visibleItems = math.max(1, math.floor((h - 4) / 2))
    if itemRow >= 1 and itemRow <= visibleItems then
      local idx = state.scroll + itemRow
      if idx >= 1 and idx <= #state.list then
        state.selected = idx
        if state.screen == "edit_list" then
          activateCurrent()
        end
      end
    end
    return
  end

  if state.screen == "rule_actions" then
    for i = 1, 3 do
      local rowY = 9 + i
      if y == rowY then
        state.actionSelected = i
        activateCurrent()
        return
      end
    end
    return
  end

  if state.screen == "form" then
    for i = 1, #state.formFields do
      local fieldY = 6 + (i - 1) * 2
      if y == fieldY and x >= 20 and x <= 35 then
        state.formSelected = i
        return
      end
    end

    if y == 14 and x >= 3 and x <= 10 then
      state.formSelected = #state.formFields + 1
      activateCurrent()
      return
    end

    if y == 14 and x >= 15 and x <= 22 then
      state.formSelected = #state.formFields + 2
      goBack()
      return
    end
  end
end

function UI.run()
  syncRuntimeRules()
  setScreenMain()

  while state.running do
    redraw()
    local event, a, b, c = os.pullEvent()

    if event == "key" then
      handleKey(a)
    elseif event == "char" then
      handleChar(a)
    elseif event == "mouse_click" then
      handleMouseClick(a, b, c)
    elseif event == "term_resize" then
      -- redraw next loop
    end
  end

  clear()
end

return UI
