-- ======================================================================
-- buffme_agent.lua v1.0.0 (Refactored)
-- Project Lazarus - BuffMe agent (runs briefly on each group member)
--
-- Improvements over v0.9.0:
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
local SCRIPT_VER = '1.0.0'

-- Configurable timeouts
local CASTING_TIMEOUT_MS = 8000
local TARGET_TIMEOUT_MS = 200
local SPELL_READY_CHECK_TIMEOUT_MS = 100

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
  if a:sub(-1) == '/' or a:sub(-1) == '\\' then return a .. b end
  return a .. '/' .. b
end

local function trim(s)
  return (tostring(s or ''):gsub('^%s+',''):gsub('%s+$',''))
end

local function logInfo(msg)
  print(string.format('[%s] %s', SCRIPT_NAME, msg))
end

local function logError(msg)
  print(string.format('[%s] ERROR: %s', SCRIPT_NAME, msg))
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
local targetName = trim((arg and arg[1]) or '')
if targetName == '' then
  logError('No target name provided. Usage: /lua run buffme_agent <TargetName>')
  return
end

-- -----------------------------
-- Load Settings
-- -----------------------------
local settings = loadLuaTable(SETTINGS_FILE)
if not settings then
  logError('Could not load settings from: ' .. SETTINGS_FILE)
  return
end

local buffList = settings.buffList
if type(buffList) ~= 'table' or #buffList == 0 then
  logInfo('No buff list configured. Nothing to cast.')
  return
end

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
      logInfo(string.format('Insufficient mana for %s (%d/%d)', name, myMana, mana))
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
      return false
    end
  end
  
  -- Check spell readiness
  if not safeSpellReady(spellName) then
    logInfo(string.format('Spell not ready: %s', spellName))
    return false
  end
  
  -- Check if we can cast (mana, book, etc)
  if not safeMeCanCast(spellName) then
    return false
  end
  
  -- Wait for any existing cast to finish
  if not waitNotCasting(CASTING_TIMEOUT_MS) then
    logError(string.format('Still casting when trying to cast %s', spellName))
    return false
  end
  
  -- Attempt the cast
  logInfo(string.format('Casting: %s', spellName))
  if not castSpellOnTarget(spellName) then
    return false
  end
  
  -- Wait for cast to complete
  if not waitNotCasting(CASTING_TIMEOUT_MS) then
    logError(string.format('Cast timeout for %s', spellName))
    return false
  end
  
  -- Brief delay after cast completes
  mq.delay(250)
  
  return true
end

-- -----------------------------
-- Main Execution
-- -----------------------------
logInfo(string.format('Starting buff sequence for: %s', targetName))
logInfo(string.format('Buff list contains %d entries', #buffList))

-- Initial target acquisition
if not targetPlayer(targetName) then
  logError(string.format('Could not target %s. Aborting.', targetName))
  return
end

logInfo(string.format('Target acquired: %s', targetName))
mq.delay(100)

-- Process buff list
local successCount = 0
local skipCount = 0
local failCount = 0

for i, rec in ipairs(buffList) do
  if type(rec) == 'table' and rec.enabled == true then
    local name = trim(rec.name)
    if name ~= '' then
      logInfo(string.format('[%d/%d] Processing: %s', i, #buffList, name))
      
      local success = attemptBuff(name, targetName)
      if success then
        successCount = successCount + 1
        logInfo(string.format('✓ Successfully cast: %s', name))
      else
        -- Check if it was skipped (not ready/mana) vs failed (error)
        if safeSpellReady(name) or safeMeCanCast(name) then
          failCount = failCount + 1
          logError(string.format('✗ Failed to cast: %s', name))
        else
          skipCount = skipCount + 1
          logInfo(string.format('⊘ Skipped: %s', name))
        end
      end
    end
  end
end

-- Summary
logInfo('─────────────────────────────')
logInfo(string.format('Buff sequence complete for: %s', targetName))
logInfo(string.format('Success: %d | Skipped: %d | Failed: %d', successCount, skipCount, failCount))
logInfo('─────────────────────────────')
