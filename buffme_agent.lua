-- ======================================================================
-- buffme_agent.lua v1.0.2 (Updated)
-- Project Lazarus - BuffMe agent (runs briefly on each group member)
--
-- v1.0.2 Updates:
--   - Version sync with controller
--   - Consistent utility functions
--   - Enhanced logging
--   - Better error reporting
--
-- v1.0.1 Improvements:
--   - Fixed string trimming to avoid gsub pattern issues
--   - Safer TLO access with pessimistic defaults
--   - Enhanced error handling and logging
--   - Explicit timeout handling
--   - Better cast verification
--   - Configurable retry logic
--
-- Called by controller via broadcast:
--   /lua run buffme_agent <TargetName>
--
-- Reads buff list from buffme_settings.lua (shared config dir).
-- Attempts to cast each enabled spell on the target, then exits.
-- ======================================================================

local mq = require('mq')

local SCRIPT_NAME = 'BuffMeAgent'
local SCRIPT_VER = '1.0.2'

-- Configurable timeouts
local CASTING_TIMEOUT_MS = 8000
local TARGET_TIMEOUT_MS = 200
local SPELL_READY_CHECK_TIMEOUT_MS = 100
local POST_CAST_DELAY_MS = 250

-- -----------------------------
-- Utility Functions
-- -----------------------------
local function getConfigDir()
  if mq.configDir then return mq.configDir end
  local p = mq.TLO.MacroQuest.Path('config')
  if p and p() and p() ~= '' then return p() end
  return '.'
end

local function joinPath(a, b)
  if not a or a == '' then return b end
  local lastChar = a:sub(-1)
  if lastChar == '/' or lastChar == '\\' then return a .. b end
  return a .. '/' .. b
end

-- Consistent with controller trim function
local function trimString(s)
  if not s then return '' end
  local str = tostring(s)
  while str:match('^%s') do
    str = str:sub(2)
  end
  while str:match('%s$') do
    str = str:sub(1, -2)
  end
  return str
end

local function logInfo(msg)
  print(string.format('[%s] %s', SCRIPT_NAME, msg))
end

local function logError(msg)
  print(string.format('[%s] ERROR: %s', SCRIPT_NAME, msg))
end

local function logWarning(msg)
  print(string.format('[%s] WARNING: %s', SCRIPT_NAME, msg))
end

-- -----------------------------
-- Configuration Loading
-- -----------------------------
local SETTINGS_FILE = joinPath(getConfigDir(), 'buffme_settings.lua')

local function loadLuaTable(path)
  local ok, t = pcall(dofile, path)
  if ok and type(t) == 'table' then return t end
  return nil
end

-- -----------------------------
-- Parse Arguments
-- -----------------------------
local targetName = trimString((arg and arg[1]) or '')
if targetName == '' then
  logError('No target name provided. Usage: /lua run buffme_agent <TargetName>')
  return
end

logInfo(string.format('v%s starting for target: %s', SCRIPT_VER, targetName))

-- -----------------------------
-- Load Settings
-- -----------------------------
local settings = loadLuaTable(SETTINGS_FILE)
if not settings then
  logError('Could not load settings from: ' .. SETTINGS_FILE)
  logError('Make sure buffme.lua controller has been run at least once.')
  return
end

-- Validate settings
if type(settings.buffList) ~= 'table' then
  logError('Invalid settings: buffList is not a table')
  return
end

local buffList = settings.buffList
if #buffList == 0 then
  logInfo('No buff list configured. Nothing to cast.')
  logInfo('Add spells via the controller GUI first.')
  return
end

-- Count enabled buffs
local enabledCount = 0
for _, rec in ipairs(buffList) do
  if type(rec) == 'table' and rec.enabled == true and type(rec.name) == 'string' and rec.name ~= '' then
    enabledCount = enabledCount + 1
  end
end

if enabledCount == 0 then
  logInfo('No enabled buffs in list. Nothing to cast.')
  return
end

logInfo(string.format('Loaded %d total buffs (%d enabled)', #buffList, enabledCount))

-- -----------------------------
-- Casting State Checks (EMU-Safe)
-- -----------------------------
local function isCasting()
  local cast = mq.TLO.Me.Casting()
  -- Treat nil or empty string as "not casting"
  return cast ~= nil and cast ~= ''
end

local function waitNotCasting(timeoutMs)
  local t0 = mq.gettime()
  while isCasting() do
    if (mq.gettime() - t0) > timeoutMs then 
      logError(string.format('Casting timeout after %dms', timeoutMs))
      return false
    end
    mq.delay(25)
  end
  return true
end

-- -----------------------------
-- Spell Readiness Checks (Conservative)
-- -----------------------------
local function safeSpellReady(name)
  -- Pessimistic: if we can't verify readiness, assume NOT ready
  local ready = mq.TLO.Me.SpellReady(name)
  if ready == nil then 
    return false  -- Cannot verify, assume not ready
  end
  
  local readyVal = ready()
  return readyVal == true
end

local function safeMeCanCast(name)
  -- Check if we have enough mana/resources to cast
  local sp = mq.TLO.Spell(name)
  if not sp or not sp() then 
    logError(string.format('Spell not found: %s', name))
    return false 
  end
  
  -- Check mana requirement
  local mana = sp.Mana and sp.Mana() or 0
  local myMana = mq.TLO.Me.CurrentMana() or 0
  
  if type(mana) == 'number' and type(myMana) == 'number' then
    if myMana < mana then
      logInfo(string.format('Insufficient mana for %s (need %d, have %d)', name, mana, myMana))
      return false
    end
  end
  
  -- Check if spell exists in book/mem
  local book = mq.TLO.Me.Book(name)
  if not book or not book() then
    logError(string.format('Spell not in book: %s', name))
    return false
  end
  
  return true
end

-- -----------------------------
-- Targeting (with verification)
-- -----------------------------
local function targetPlayer(name)
  mq.cmdf('/target %s', name)
  mq.delay(TARGET_TIMEOUT_MS)
  
  local tn = mq.TLO.Target.Name()
  if not tn or tn == '' then
    return false
  end
  
  return tn:lower() == name:lower()
end

local function verifyTarget(name)
  local tn = mq.TLO.Target.Name()
  if not tn or tn == '' then
    return false
  end
  return tn:lower() == name:lower()
end

-- -----------------------------
-- Spell Casting (with verification)
-- -----------------------------
local function castSpellOnTarget(spellName)
  local ok, err = pcall(function()
    mq.cmdf('/cast "%s"', spellName)
  end)
  
  if not ok then
    logError(string.format('Failed to cast %s: %s', spellName, tostring(err)))
    return false
  end
  
  return true
end

local function attemptBuff(spellName, targetName)
  -- Verify we still have target
  if not verifyTarget(targetName) then
    if not targetPlayer(targetName) then
      logError(string.format('Lost target: %s', targetName))
      return false, 'lost_target'
    end
  end
  
  -- Check spell readiness
  if not safeSpellReady(spellName) then
    logInfo(string.format('Spell not ready: %s', spellName))
    return false, 'not_ready'
  end
  
  -- Check if we can cast (mana, book, etc)
  if not safeMeCanCast(spellName) then
    return false, 'cannot_cast'
  end
  
  -- Wait for any existing cast to finish
  if not waitNotCasting(CASTING_TIMEOUT_MS) then
    logError(string.format('Still casting when trying to cast %s', spellName))
    return false, 'still_casting'
  end
  
  -- Attempt the cast
  logInfo(string.format('Casting: %s', spellName))
  if not castSpellOnTarget(spellName) then
    return false, 'cast_failed'
  end
  
  -- Wait for cast to complete
  if not waitNotCasting(CASTING_TIMEOUT_MS) then
    logError(string.format('Cast timeout for %s', spellName))
    return false, 'cast_timeout'
  end
  
  -- Brief delay after cast completes
  mq.delay(POST_CAST_DELAY_MS)
  
  return true, 'success'
end

-- -----------------------------
-- Main Execution
-- -----------------------------
logInfo('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━')
logInfo(string.format('Starting buff sequence for: %s', targetName))
logInfo(string.format('Buff list contains %d entries (%d enabled)', #buffList, enabledCount))

-- Initial target acquisition
if not targetPlayer(targetName) then
  logError(string.format('Could not target %s. Aborting.', targetName))
  logError('Make sure the target is in the same zone and /targetable')
  return
end

logInfo(string.format('Target acquired: %s', targetName))
mq.delay(100)

-- Process buff list
local successCount = 0
local skipCount = 0
local failCount = 0
local results = {
  success = {},
  skipped = {},
  failed = {}
}

for i, rec in ipairs(buffList) do
  if type(rec) == 'table' and rec.enabled == true then
    local name = trimString(rec.name)
    if name ~= '' then
      logInfo(string.format('[%d/%d] Processing: %s', i, #buffList, name))
      
      local success, reason = attemptBuff(name, targetName)
      if success then
        successCount = successCount + 1
        logInfo(string.format('✓ Successfully cast: %s', name))
        table.insert(results.success, name)
      else
        -- Categorize the failure
        if reason == 'not_ready' or reason == 'cannot_cast' then
          skipCount = skipCount + 1
          logInfo(string.format('⊘ Skipped: %s (%s)', name, reason))
          table.insert(results.skipped, {name = name, reason = reason})
        else
          failCount = failCount + 1
          logError(string.format('✗ Failed to cast: %s (%s)', name, reason))
          table.insert(results.failed, {name = name, reason = reason})
        end
      end
      
      -- Brief pause between attempts
      mq.delay(100)
    end
  end
end

-- Summary
logInfo('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━')
logInfo(string.format('Buff sequence complete for: %s', targetName))
logInfo(string.format('Results: %d success | %d skipped | %d failed', successCount, skipCount, failCount))

if successCount > 0 then
  logInfo(string.format('Successfully cast %d buffs:', successCount))
  for _, name in ipairs(results.success) do
    logInfo(string.format('  ✓ %s', name))
  end
end

if skipCount > 0 then
  logInfo(string.format('Skipped %d buffs (not ready/no mana):', skipCount))
  for _, entry in ipairs(results.skipped) do
    logInfo(string.format('  ⊘ %s (%s)', entry.name, entry.reason))
  end
end

if failCount > 0 then
  logError(string.format('Failed to cast %d buffs:', failCount))
  for _, entry in ipairs(results.failed) do
    logError(string.format('  ✗ %s (%s)', entry.name, entry.reason))
  end
end

logInfo('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━')
logInfo('Agent complete. Exiting.')
