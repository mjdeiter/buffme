-- ======================================================================
-- buffme_agent.lua
-- Project Lazarus - BuffMe agent (runs briefly on each group member)
--
-- Called by controller via broadcast:
--   /lua run buffme_agent <TargetName>
--
-- Reads buff list from buffme_settings.lua (shared config dir).
-- Attempts to cast each enabled spell on the target, then exits.
-- ======================================================================

local mq = require('mq')

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

local SETTINGS_FILE = joinPath(getConfigDir(), 'buffme_settings.lua')

local function loadLuaTable(path)
  local ok, t = pcall(dofile, path)
  if ok and type(t) == 'table' then return t end
  return nil
end

local function trim(s)
  return (tostring(s or ''):gsub('^%s+',''):gsub('%s+$',''))
end

local targetName = trim((arg and arg[1]) or '')
if targetName == '' then
  print('[buffme_agent] No target name provided.')
  return
end

local settings = loadLuaTable(SETTINGS_FILE) or {}
local buffList = settings.buffList
if type(buffList) ~= 'table' or #buffList == 0 then
  print('[buffme_agent] No buff list configured.')
  return
end

local function isCasting()
  local cast = mq.TLO.Me.Casting()
  return cast ~= nil and cast ~= ''
end

local function waitNotCasting(timeoutMs)
  local t0 = mq.gettime()
  while isCasting() do
    if (mq.gettime() - t0) > timeoutMs then break end
    mq.delay(25)
  end
end

local function safeSpellReady(name)
  local r = mq.TLO.Me.SpellReady(name)
  if r == nil then return true end
  return r() == true
end

local function safeMeCanCast(name)
  local sp = mq.TLO.Spell(name)
  if sp and sp() then
    local mana = sp.Mana and sp.Mana() or 0
    local myMana = mq.TLO.Me.CurrentMana() or 0
    if mana and myMana and myMana < mana then return false end
  end
  return true
end

local function targetPlayer(name)
  mq.cmdf('/target %s', name)
  mq.delay(200)
  local tn = mq.TLO.Target.Name()
  return tn ~= nil and tn ~= '' and tn:lower() == name:lower()
end

local function castSpellOnTarget(spellName)
  mq.cmdf('/cast "%s"', spellName)
end

print(string.format('[buffme_agent] Buffing %s...', targetName))

if not targetPlayer(targetName) then
  print('[buffme_agent] Could not target ' .. targetName .. '. Aborting.')
  return
end

mq.delay(100)

for _,rec in ipairs(buffList) do
  if type(rec) == 'table' and rec.enabled == true then
    local name = trim(rec.name)
    if name ~= '' then
      targetPlayer(targetName)
      if safeSpellReady(name) and safeMeCanCast(name) then
        waitNotCasting(3000)
        castSpellOnTarget(name)
        waitNotCasting(8000)
        mq.delay(250)
      end
    end
  end
end

print(string.format('[buffme_agent] Done buffing %s.', targetName))
