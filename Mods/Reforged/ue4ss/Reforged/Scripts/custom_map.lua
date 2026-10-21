-- custom_map.lua (#93): Reforged module for custom test maps (Well That's Orcward).
-- Ported from scripts/testmap/ue4ss/TestMapProbe/Scripts/main.lua (#89, #91, #94, #97). The probe stays until the live check.
-- Pure functions (M.*, no game calls) are tested under lupa.lua54 in director/test_custom_map.py.
-- M.Start(env) runs the game part. main.lua passes env: GameLoop, GameDelay, WatchEmit, GuidFromString,
-- Testing(), TestMode(), Diag(), HubOpen(), ConsoleExec(text), RegisterKeyBind, Key (#93 M2).
-- Nothing runs on a world whose name is not a key of M.MAPS.
-- Log tag: "[Reforged] custom-map <body>". The bodies match the probe, so scripts/testmap/mapctl.py reads both.
-- Timed work runs through env.GameLoop and env.GameDelay only (game thread). No LoopAsync or ExecuteWithDelay here.

local M = {}

M.TAG = "[Reforged] custom-map "
M.TEST_PREFIX = "/Game/Maps/Test/"
-- One row per custom map. The key is the short map name (the last path part of the world).
-- borrow: the end-of-match mission the map needs (campaign, mission GUID, retryMap). #102: the custom maps use their own
-- Endless rows (campaign "Endless"). The borrowed difficulty is the Endless value, read at run time (ENV.EndlessDifficulty).
-- enemyPath: "stock" = the stock controller follows the map's OMDAIPath; "walk" = engine AIController walks to the Rift.
M.MAPS = {
  WellThatsOrcward = {
    path = "/Game/Maps/Test/WellThatsOrcward",
    title = "Well That's Orcward",
    borrow = { campaign = "Endless", mission = "35AB4658-44C8-5E5D-B847-901217630F57", retryMap = "WellThatsOrcward" },
    enemyPath = "stock",
  },
  ServantEntrance = {
    path = "/Game/Maps/Test/ServantEntrance",
    title = "Servant Entrance",
    borrow = { campaign = "Endless", mission = "B6232412-0A9F-584B-B16D-A87541EFE134", retryMap = "ServantEntrance" },
    enemyPath = "stock",
  },
}
-- The launch key (F8, custom-map-launch) opens the first entry. Keys in this list are the keys of M.MAPS, in order.
M.MAP_ORDER = { "WellThatsOrcward", "ServantEntrance" }
M.SPAWN_TAG = "OMDSpawn="
M.PROP_TAG = "OMDProp="
M.SET_TAG = "OMDSet="  -- #98 M2: OMDSet=<key>=<value> sets a property on the spawned actor (ParseSetTag).
-- Apply order for OMDProp keys (#94 spec 2.3): Mobility, IntensityUnits, the other keys, then bUseInverseSquaredFalloff.
M.PROP_ORDER = { "Mobility", "IntensityUnits", "Intensity", "LightColor", "AttenuationRadius",
  "LightFalloffExponent", "CastShadows", "LightingChannels", "bUseInverseSquaredFalloff" }
M.PROP_INDEX = {}
for i, k in ipairs(M.PROP_ORDER) do M.PROP_INDEX[k] = i end
M.COIN_FULL, M.COIN_LOW = 999999, 500000
M.RIFT_REACH = 300
-- Music stays off: SpawnSound2D from Lua crashed UE4SS 83330635 at music start (2026-10-20).
M.MUSIC_ENABLED = false
M.MUSIC_CUE_PATH = "/Game/Sounds/Music/Cues/Final/Battle/MX_OMD3_Battle_02_LP_SC"
M.MUSIC_START_MAX = 3
M.DIAG_HOOKS = {
  { "/Script/OMD.OMDPlayerCharacter:BP_TrapPlaced", "TrapPlaced" },
  { "/Script/OMD.OMDTrapPlacementFX:BP_ChangeStatus", "PlacementStatus" },
  { "/Script/OMD.OMDTrapPlacementFX:BP_CantPlaceHere", "CantPlaceHere" },
  { "/Script/OMD.OMDTrapPlacementFX:BP_Placeable", "Placeable" },
  { "/Script/OMD.OMDTrapPlacementFX:BP_NotEnoughCoin", "NotEnoughCoin" },
}

-- ---------- pure functions ----------

-- The map key for a world full name, e.g. "WorldSettings /Game/Maps/Test/WellThatsOrcward.WellThatsOrcward:...".
-- nil when the name has no Test map part or the short name is not a key of M.MAPS (a stock world).
-- The short map name of a world full name: the part before the first "." after a "/", e.g.
-- "WorldSettings /Game/Maps/North_Wing/Scenario_01.Scenario_01:..." gives "Scenario_01". nil when there is none.
function M.ShortName(worldName)
  if type(worldName) ~= "string" then return nil end
  return worldName:match("/([%w_]+)%.")
end

function M.MapFromWorld(name)
  if type(name) ~= "string" or name:find(M.TEST_PREFIX, 1, true) == nil then return nil end
  local short = M.ShortName(name)
  if short == nil or M.MAPS[short] == nil then return nil end
  return short
end

-- #103 phase 1: the match-start title card. The stock widget and its hook path. The card text is set again after the
-- widget's own 0.75 s wait (the stock Construct sets it from the row's MissionName).
M.INTRO_WIDGET = "/Game/UI/ScenarioIntro/UBP_GenericScenarioIntro"
M.INTRO_CLASS = "/Game/UI/ScenarioIntro/UBP_GenericScenarioIntro.UBP_GenericScenarioIntro_C"
M.INTRO_HOOK = "/Game/Game/BP_OMDGameInstance.BP_OMDGameInstance_C:HideLoadingScreen"
M.INTRO_TEXT_DELAY = 1200

-- "title" for a key of M.MAPS (a custom map), "none" for nil, a stock key or any other value.
function M.IntroKind(key)
  if type(key) == "string" and M.MAPS[key] ~= nil then return "title" end
  return "none"
end

-- #100 items 5.2: the borrowed difficulty (1) stays on a custom map in Classic, so the native win can run.
-- True only when the world is a custom map and the Endless mode is classic. Manual and Reforged keep the fix.
function M.KeepsBorrowedDifficulty(worldName, mode)
  return mode == "classic" and M.MapFromWorld(worldName) ~= nil
end

-- The campaign field of the game instance that holds a borrow's campaign table. "Endless" is gi.EndlessCampaign (#102).
function M.CampaignField(campaign)
  if campaign == "Endless" then return "EndlessCampaign" end
  return campaign
end

-- The difficulty to borrow. An Endless row takes the Endless value that the caller reads at run time. Other rows
-- keep their own value. nil when neither is set.
function M.BorrowDifficulty(borrow, endlessDifficulty)
  if borrow.campaign == "Endless" then return endlessDifficulty end
  return borrow.difficulty
end

-- #100 item 7.4: RETRY on a custom map's end screen reopens the borrowed mission map. #102: RETRY opens the mission level
-- natively now (the custom map's own Test level), so the reopen is for the map's own short name only and never
-- targets the custom map itself (no second launch). The reopen is allowed only within RETRY_WINDOW seconds. Returns fromKey, or nil.
M.RETRY_WINDOW = 600
function M.RetryTarget(fromKey, shortName, elapsed)
  if fromKey == nil or M.MAPS[fromKey] == nil then return nil end
  if shortName == nil or shortName ~= M.MAPS[fromKey].borrow.retryMap then return nil end
  if shortName == fromKey then return nil end
  if type(elapsed) ~= "number" or elapsed ~= elapsed or elapsed < 0 or elapsed > M.RETRY_WINDOW then return nil end
  return fromKey
end

function M.MapCount()
  local n = 0
  for _ in pairs(M.MAPS) do n = n + 1 end
  return n
end

-- The map key to launch: nil name gives the first MAP_ORDER entry. A name must be a key of M.MAPS. nil when unknown.
function M.LaunchKey(name)
  if name == nil then return M.MAP_ORDER[1] end
  if M.MAPS[name] ~= nil then return name end
  return nil
end

-- The class path of the last OMDSpawn= tag, or nil. tags is a list of tag strings.
function M.SpawnPath(tags)
  local found = nil
  for _, t in ipairs(tags) do
    if t:sub(1, #M.SPAWN_TAG) == M.SPAWN_TAG then found = t:sub(#M.SPAWN_TAG + 1) end
  end
  return found
end

function M.IsCoordinatorPath(path)
  return path ~= nil and path:find("Coordinator", 1, true) ~= nil
end

-- Returns { [comp] = { {key, valueText}, ... } } from the OMDProp=<comp>.<key>=<value> tags.
function M.PropsFromTags(tags)
  local out = {}
  for _, t in ipairs(tags) do
    if t:sub(1, #M.PROP_TAG) == M.PROP_TAG then
      local comp, key, val = t:sub(#M.PROP_TAG + 1):match("^([^%.]+)%.([^=]+)=(.*)$")
      if comp then
        out[comp] = out[comp] or {}
        out[comp][#out[comp] + 1] = { key, val }
      end
    end
  end
  return out
end

-- Parses one OMDSet=<key>=<value> tag (#98 M2). Returns key and value (a number, true or false), or nil for a tag
-- that is not a set tag or whose value is none of those.
function M.ParseSetTag(tag)
  if type(tag) ~= "string" or tag:sub(1, #M.SET_TAG) ~= M.SET_TAG then return nil end
  local key, val = tag:sub(#M.SET_TAG + 1):match("^([^=]+)=(.*)$")
  if key == nil then return nil end
  if val == "true" then return key, true end
  if val == "false" then return key, false end
  local n = tonumber(val)
  if n == nil then return nil end
  return key, n
end

-- Index of the point nearest to (x, y) in 2D. points is a list of { x=, y= }. Nil for an empty list (#98 M2).
function M.NearestStart(points, x, y)
  local best, bestD = nil, nil
  for i, p in ipairs(points) do
    local dx, dy = p.x - x, p.y - y
    local d = dx * dx + dy * dy
    if bestD == nil or d < bestD then best, bestD = i, d end
  end
  return best
end

-- Splits one component's entries into byKey (known keys) and a count of unknown keys.
function M.SplitPropEntries(entries)
  local byKey, unknown = {}, 0
  for _, e in ipairs(entries) do
    if M.PROP_INDEX[e[1]] then byKey[e[1]] = e[2] else unknown = unknown + 1 end
  end
  return byKey, unknown
end

function M.PropNum(v)
  local n = tonumber(v)
  if n == nil then error("not a number: " .. tostring(v), 0) end
  return n
end

function M.PropBool(v)
  if v == "true" then return true end
  if v == "false" then return false end
  error("not a bool: " .. tostring(v), 0)
end

function M.PropList(v, count)
  local parts = {}
  for p in (v .. ","):gmatch("([^,]*),") do parts[#parts + 1] = p end
  if #parts < count then error("need " .. count .. " values: " .. tostring(v), 0) end
  return parts
end

-- Spawn order. records: { ref=, path=, props= } in marker order; a record with no path is not a spawn and is dropped.
-- Plan: the non-coordinator records, then one { borrow = true }, then the coordinator records (#89 M6).
-- The borrow is before the first coordinator, or at the end when the map has none.
function M.SpawnPlan(records)
  local first, coords, plan = {}, {}, {}
  for _, r in ipairs(records) do
    if r.path ~= nil then
      if M.IsCoordinatorPath(r.path) then coords[#coords + 1] = r else first[#first + 1] = r end
    end
  end
  for _, r in ipairs(first) do plan[#plan + 1] = r end
  plan[#plan + 1] = { borrow = true }
  for _, r in ipairs(coords) do plan[#plan + 1] = r end
  return plan
end

-- Coin top-up runs only in test mode (TEST_MODE, or `testing on`).
function M.CoinGate(testMode, testing)
  return testMode == true or testing == true
end

-- The mission GUID to borrow, from the map row. nil when the key is not a map.
function M.BorrowGuid(key, guidFromString)
  local row = M.MAPS[key]
  if row == nil then return nil end
  return guidFromString(row.borrow.mission)
end

-- Rotator (degrees, Pitch/Yaw/Roll) to quaternion table.
function M.RotQuat(r)
  local d = math.pi / 360
  local sp, cp = math.sin(r.Pitch * d), math.cos(r.Pitch * d)
  local sy, cy = math.sin(r.Yaw * d), math.cos(r.Yaw * d)
  local sr, cr = math.sin(r.Roll * d), math.cos(r.Roll * d)
  return { X = cr * sp * sy - sr * cp * cy, Y = -cr * sp * cy - sr * cp * sy,
           Z = cr * cp * sy - sr * sp * cy, W = cr * cp * cy + sr * sp * sy }
end

-- #103 C1: the announcer cue for one door reading. door is the door's state table (hp0, hpPrev, open, attacked, againAt),
-- updated in place. i is the door number (1 is the first door of the map). now is the time in s. hp is Health (a number
-- or nil). open is bIsOpen (a boolean or nil). The first reading only sets the state. Returns cue, delay: cue is the
-- name or nil, delay is the wait in s before the play (0.5 for the first hit and the breach, 0 for an again).
-- Door 1 gets AttackedFirst and Breached. Other doors get AttackedNext and BreachedNext (stock keying, per door number).
-- A drop after the first hit plays AttackedAgain at most once per 10 s.
function M.DoorCue(door, i, now, hp, open)
  if door.hp0 == nil then
    if hp ~= nil then door.hp0, door.hpPrev = hp, hp end
    door.open = open == true
    door.attacked, door.againAt = false, 0
    return nil, 0
  end
  local first = i == 1
  local wasOpen = door.open
  if open ~= nil then door.open = open end
  local cue, delay = nil, 0
  if hp ~= nil and hp < (door.hpPrev or door.hp0) then
    if not door.attacked then
      door.attacked, door.againAt = true, now + 10
      cue, delay = first and "AttackedFirst" or "AttackedNext", 0.5
    elseif now >= door.againAt then
      door.againAt = now + 10
      cue = "AttackedAgain"
    end
  end
  if hp ~= nil then door.hpPrev = hp end
  if open == true and not wasOpen then
    cue, delay = first and "Breached" or "BreachedNext", 0.5
  end
  return cue, delay
end

-- ---------- game part (needs ENV from M.Start) ----------

local ENV = nil
local S = { world = nil, key = nil, worldKey = nil,
  pawnPrints = 0, postgame = false, hooks = false, walkers = {}, walkDone = {}, walkLogs = 0,
  coinLogs = 0, lastStatus = nil, lastTraps = nil, musicComp = nil, musicFlag = nil, musicAttempts = 0,
  errLogs = 0, retryFrom = nil, retryAt = nil, pathLogs = 0, pathCapped = false, introWorld = nil,
  inputGen = 0, inputPending = false, inputAt = 0 }

local function Log(body)
  print(M.TAG .. body)
end

local function Emit(ev, fields)
  if ENV and type(ENV.WatchEmit) == "function" then pcall(ENV.WatchEmit, ev, fields) end
end

local function Diag()
  return ENV ~= nil and type(ENV.Diag) == "function" and ENV.Diag() == true
end

local function CoinOn()
  return ENV ~= nil and M.CoinGate(ENV.TestMode and ENV.TestMode(), ENV.Testing and ENV.Testing())
end

-- Runs fn in pcall. The first 5 errors print one line each, so a bad tick shows in the log.
local function Guard(label, fn)
  return function()
    local ok, err = pcall(fn)
    if not ok and S.errLogs < 5 then
      S.errLogs = S.errLogs + 1
      Log("error label=" .. label .. " err=" .. tostring(err))
    end
    return false
  end
end

local function TagStrings(a)
  local out = {}
  pcall(function()
    a.Tags:ForEach(function(_, elem) out[#out + 1] = elem:get():ToString() end)
  end)
  return out
end

-- #103: the world key is the WorldSettings full name, then "@" and the object address. A reload of the same map has the
-- same full name, so the address tells the two worlds apart. The address is added only when it can be read.
-- Returns the key and the full name. Both are "none" when no WorldSettings is valid.
local function WorldKey()
  local ws = FindFirstOf("WorldSettings")
  if not (ws and ws:IsValid()) then return "none", "none" end
  local name = ws:GetFullName()
  local key = name
  local okA, addr = pcall(function() return ws:GetAddress() end)
  if okA and addr ~= nil and addr ~= 0 then
    local okF, hex = pcall(string.format, "%x", addr)
    key = name .. "@" .. (okF and hex or tostring(addr))
  end
  return key, name
end

-- End-of-match mission (#89 corridor): the end code reads the mission with no null check, and the map opens with none.
-- SetCurrentCampaign runs before the difficulty set, because it rewrites the difficulty (Reforged SetEndlessDifficulty).
-- The Endless difficulty, read at run time from main.lua through ENV.EndlessDifficulty. nil when not supplied.
local function EndlessDifficultyValue()
  if ENV and type(ENV.EndlessDifficulty) == "function" then return ENV.EndlessDifficulty() end
  return nil
end

local function BorrowMission(key)
  local row = M.MAPS[key]
  local b = row.borrow
  local gi
  pcall(function() gi = FindFirstOf("BP_OMDGameInstance_C") end)
  if not gi or not gi:IsValid() then
    pcall(function() gi = FindFirstOf("OMDGameInstance") end)
  end
  if not gi or not gi:IsValid() then
    Log("mission borrow campaign=false difficulty=false mission=false err=game instance not found")
    return false
  end
  local firstErr = nil
  local function Try(f)
    local ok, e = pcall(f)
    if not ok and firstErr == nil then firstErr = tostring(e) end
    return ok
  end
  local campaign
  local okBuild = Try(function()
    local g = gi[M.CampaignField(b.campaign)].Guid
    campaign = { Guid = { A = g.A, B = g.B, C = g.C, D = g.D } }
  end)
  local okCampaign = okBuild and Try(function() gi:SetCurrentCampaign(campaign) end)
  local okDiff = Try(function()
    local d = M.BorrowDifficulty(b, EndlessDifficultyValue())
    if d == nil then error("no borrow difficulty", 0) end
    gi:SetCurrentDifficulty(d)
  end)
  local okMission = Try(function()
    local guid = M.BorrowGuid(key, ENV.GuidFromString)
    if guid == nil then error("bad mission guid", 0) end
    gi:SetCurrentMission({ Guid = guid })
  end)
  Log(string.format("mission borrow campaign=%s difficulty=%s mission=%s%s",
    tostring(okCampaign), tostring(okDiff), tostring(okMission), firstErr and (" err=" .. firstErr) or ""))
  Emit("custom-map", { phase = "borrow", map = key, campaign = okCampaign == true, difficulty = okDiff == true, mission = okMission == true })
  return okMission == true
end

-- Default light block when a marker has no OMDProp tags: movable, no shadows. A component counts when either call is ok.
local function DefaultLights(actor)
  local lights = 0
  for _, lname in ipairs({ "Torch_Point_Static", "Torch_Point_Static1", "Torch_Point_Static2" }) do
    local okC, comp = pcall(function() return actor[lname] end)
    if okC and comp and comp:IsValid() then
      local okM = pcall(function() comp:SetMobility(2) end)
      local okS = pcall(function() comp:SetCastShadows(false) end)
      if okM or okS then lights = lights + 1 end
    end
  end
  return lights
end

-- Applies one component's OMDProp keys to actor[comp]. Each key runs in its own pcall. One line per component.
local function ApplyCompProps(actor, clsName, comp, entries)
  local byKey, unknown = M.SplitPropEntries(entries)
  local set, fail = 0, unknown
  local okC, c = pcall(function() return actor[comp] end)
  local okV, valid = false, false
  if okC and c then okV, valid = pcall(function() return c:IsValid() end) end
  if not (okV and valid) then
    Log(string.format("props class=%s comp=%s set=0 fail=%d", clsName, comp, #entries))
    return
  end
  for _, key in ipairs(M.PROP_ORDER) do
    local v = byKey[key]
    if v ~= nil then
      local ok = pcall(function()
        if key == "Mobility" then c:SetMobility(M.PropNum(v))
        elseif key == "IntensityUnits" then c:SetIntensityUnits(M.PropNum(v))
        elseif key == "Intensity" then c:SetIntensity(M.PropNum(v))
        elseif key == "LightColor" then
          local p = M.PropList(v, 3)
          c:SetLightColor({ R = M.PropNum(p[1]) / 255, G = M.PropNum(p[2]) / 255, B = M.PropNum(p[3]) / 255, A = 1 }, true)
        elseif key == "AttenuationRadius" then c:SetAttenuationRadius(M.PropNum(v))
        elseif key == "LightFalloffExponent" then c:SetLightFalloffExponent(M.PropNum(v))
        elseif key == "CastShadows" then c:SetCastShadows(M.PropBool(v))
        elseif key == "LightingChannels" then
          local p = M.PropList(v, 3)
          c:SetLightingChannels(M.PropBool(p[1]), M.PropBool(p[2]), M.PropBool(p[3]))
        elseif key == "bUseInverseSquaredFalloff" then
          c.bUseInverseSquaredFalloff = M.PropBool(v)
          c:SetVisibility(false, false)
          c:SetVisibility(true, false)
        end
      end)
      if ok then set = set + 1 else fail = fail + 1 end
    end
  end
  Log(string.format("props class=%s comp=%s set=%d fail=%d", clsName, comp, set, fail))
end

-- Diagnostic listing of one spawned actor's meshes, bounds, grid boxes and components. Diag only: each one is a
-- FindAllOf over every component, which is O(n^2) on the game thread (2026-10-20 exit with 55 markers).
local function DiagActor(actor, cls, cname)
  local actorName = actor:GetFullName()
  local meshes = {}
  for _, mc in ipairs(FindAllOf("StaticMeshComponent") or {}) do
    pcall(function()
      local owner = mc:GetOwner()
      if owner and owner:IsValid() and owner:GetFullName() == actorName then
        local mesh = mc.StaticMesh
        meshes[#meshes + 1] = mc:GetFName():ToString() .. "=" .. ((mesh and mesh:IsValid()) and mesh:GetFName():ToString() or "none")
      end
    end)
  end
  local bo, be = {}, {}
  local okB = pcall(function() actor:GetActorBounds(false, bo, be, false) end)
  local grid = "-"
  pcall(function() grid = tostring(actor.GridScale) end)
  Log(string.format("spawn bounds class=%s ok=%s origin=%.0f,%.0f,%.0f extent=%.0f,%.0f,%.0f grid=%s",
    cname, tostring(okB), bo.X or -1, bo.Y or -1, bo.Z or -1, be.X or -1, be.Y or -1, be.Z or -1, grid))
  local nGrid = 0
  for _, gb in ipairs(FindAllOf("OMDTrapGridBoxComponent") or {}) do
    pcall(function()
      local owner = gb:GetOwner()
      if owner and owner:IsValid() and owner:GetFullName() == actorName and nGrid < 4 then
        nGrid = nGrid + 1
        local wl = gb:K2_GetComponentLocation()
        local ex = gb:GetScaledBoxExtent()
        local fwd = gb:GetForwardVector()
        local up = gb:GetUpVector()
        Log(string.format("grid %s %s loc=%.0f,%.0f,%.0f extent=%.0f,%.0f,%.0f fwd=%.2f,%.2f,%.2f up=%.2f,%.2f,%.2f types=%s war=%s",
          cname, gb:GetFName():ToString(), wl.X, wl.Y, wl.Z, ex.X, ex.Y, ex.Z, fwd.X, fwd.Y, fwd.Z, up.X, up.Y, up.Z,
          tostring(gb.TrapPlacementTypes), tostring(gb.TrapWarMachineTypes)))
      end
    end)
  end
  if not cname:find("^Floor_") and not cname:find("^Wall_") then
    local comps = {}
    for _, sc in ipairs(FindAllOf("SceneComponent") or {}) do
      pcall(function()
        local owner = sc:GetOwner()
        if owner and owner:IsValid() and owner:GetFullName() == actorName and #comps < 25 then
          local wl = sc:K2_GetComponentLocation()
          comps[#comps + 1] = string.format("%s:%s@%.0f,%.0f,%.0f", sc:GetClass():GetFName():ToString(), sc:GetFName():ToString(), wl.X, wl.Y, wl.Z)
        end
      end)
    end
    Log("comps " .. cname .. " n=" .. #comps .. " " .. table.concat(comps, " "))
  end
  local root = "none"
  pcall(function() root = actor.RootComponent:GetFullName() end)
  Log("spawn root " .. root)
  return meshes
end

-- One marker. Returns true on a spawned actor, or false and the error text.
local function SpawnOne(rec)
  local m, path, props, sets = rec.ref, rec.path, rec.props, rec.sets or {}
  local gs = StaticFindObject("/Script/Engine.Default__GameplayStatics")
  local out = { lights = 0, meshes = {} }
  local ok, err = pcall(function()
    local okL, errL = pcall(LoadAsset, path)
    local cls = StaticFindObject(path)
    if not cls or not cls:IsValid() then error("class not found after LoadAsset ok=" .. tostring(okL) .. " " .. tostring(errL), 0) end
    local l, r, sc = m:K2_GetActorLocation(), m:K2_GetActorRotation(), m:GetActorScale3D()
    local tf = { Rotation = M.RotQuat(r), Translation = { X = l.X, Y = l.Y, Z = l.Z }, Scale3D = { X = sc.X, Y = sc.Y, Z = sc.Z } }
    local actor = gs:BeginDeferredActorSpawnFromClass(m, cls, tf, 1, nil)
    if not actor or not actor:IsValid() then error("begin spawn returned no actor", 0) end
    -- OMDSet tags (#98 M2) set a property before the spawn finishes.
    for _, st in ipairs(sets) do
      local okSet = pcall(function() actor[st[1]] = st[2] end)
      Log(string.format("set %s=%s ok=%s", st[1], tostring(st[2]), tostring(okSet)))
    end
    gs:FinishSpawningActor(actor, tf)
    local cname = cls:GetFName():ToString()
    if M.IsCoordinatorPath(path) then
      local rift = "?"
      pcall(function()
        local rp = FindFirstOf("OMDGameState").RiftPoints
        if rp ~= nil then rift = tostring(rp) end
      end)
      Log(string.format("coordinator ok class=%s rift=%s", cname, rift))
    end
    -- OMDProp tags on the marker set the components. Without tags, the default light block runs.
    if next(props) ~= nil then
      for comp, entries in pairs(props) do
        ApplyCompProps(actor, cname, comp, entries)
        out.lights = out.lights + 1
      end
    else
      out.lights = DefaultLights(actor)
    end
    local nl = actor:K2_GetActorLocation()
    if Diag() then out.meshes = DiagActor(actor, cls, cname) end
    Log(string.format("spawn ok class=%s actor=%s loc=%.0f,%.0f,%.0f yaw=%.0f meshes=%d [%s] lights=%d",
      cname, actor:GetFName():ToString(), nl.X, nl.Y, nl.Z, actor:K2_GetActorRotation().Yaw,
      #out.meshes, table.concat(out.meshes, " "), out.lights))
  end)
  if not ok then Log("spawn fail path=" .. path .. " err=" .. tostring(err)) end
  return ok
end

-- Runs the spawn plan once per world (called on the world change).
local function SpawnAll(key)
  local recs = {}
  for _, m in ipairs(FindAllOf("TargetPoint") or {}) do
    local tags = TagStrings(m)
    local sets = {}
    for _, t in ipairs(tags) do
      local k, v = M.ParseSetTag(t)
      if k ~= nil then sets[#sets + 1] = { k, v } end
    end
    recs[#recs + 1] = { ref = m, path = M.SpawnPath(tags), props = M.PropsFromTags(tags), sets = sets }
  end
  local plan = M.SpawnPlan(recs)
  local spawned, failed = 0, 0
  for _, step in ipairs(plan) do
    if step.borrow then
      BorrowMission(key)
    elseif SpawnOne(step) then
      spawned = spawned + 1
    else
      failed = failed + 1
    end
  end
  Emit("custom-map", { phase = "spawned", map = key, spawned = spawned, failed = failed })
end

local function InputState(tag, pc)
  pcall(function()
    local function B(f) local ok, v = pcall(f); return ok and tostring(v) or "?" end
    Log(string.format("input %s pc=%s moveIgnored=%s lookIgnored=%s cursor=%s pawn=%s",
      tag, pc:GetFName():ToString(), B(function() return pc:IsMoveInputIgnored() end), B(function() return pc:IsLookInputIgnored() end),
      B(function() return pc.bShowMouseCursor end), B(function() return pc.Pawn:GetFName():ToString() end)))
  end)
end

-- #103 input fix. A custom map never runs the stock end-of-load steps (HideLoadingScreen, PlayLevelIntro),
-- so the input fix runs here in three passes. Each pass takes its controller from PlayerCtl.
local function Valid(o)
  if o == nil then return false end
  local ok, v = pcall(function() return o:IsValid() end)
  return ok and v == true
end

-- The world object for GameplayStatics: the WorldSettings actor, or the world of the old PlayerController.
local function WorldObject()
  local ws = FindFirstOf("WorldSettings")
  if Valid(ws) then return ws end
  local old = FindFirstOf("PlayerController")
  if Valid(old) then
    local ok, w = pcall(function() return old:GetWorld() end)
    if ok and Valid(w) then return w end
  end
  return nil
end

-- Player 0 (GameplayStatics GetPlayerController). FindFirstOf("OMDPlayerController") when that gives nothing.
local function PlayerCtl(world)
  if world ~= nil then
    local ok, pc = pcall(function()
      return StaticFindObject("/Script/Engine.Default__GameplayStatics"):GetPlayerController(world, 0)
    end)
    if ok and Valid(pc) then return pc end
  end
  local okF, pc = pcall(FindFirstOf, "OMDPlayerController")
  if okF and Valid(pc) then return pc end
  return nil
end

-- The controller for an input pass. nil and the reason when there is no controller or no pawn.
local function InputReady()
  local pc = PlayerCtl(WorldObject())
  if pc == nil then return nil, "nopc" end
  local okP, pawn = pcall(function() return pc.Pawn end)
  if not (okP and Valid(pawn)) then return nil, "nopawn" end
  return pc, nil
end

-- Game input on test maps (#89): reset the ignore flags, show no cursor, game-only input, enable the pawn.
local function ForceGameInput(pc)
  local steps = {}
  local function St(name, f) local ok, e = pcall(f); steps[#steps + 1] = name .. "=" .. tostring(ok) .. (ok and "" or ("(" .. tostring(e) .. ")")) end
  St("resetIgnore", function() pc:ResetIgnoreInputFlags() end)
  St("cursor", function() pc.bShowMouseCursor = false end)
  St("gameOnly", function()
    local wbl = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    wbl:SetInputMode_GameOnly(pc)
  end)
  St("enablePawn", function() pc.Pawn:EnableInput(pc) end)
  Log("input fix " .. table.concat(steps, " "))
end

local function AllowPlay(pc)
  local ok, err = pcall(function()
    pc.Pawn:SetPlayerInputValues(true, false, false, true, true, true, true)
  end)
  Log("allow-play SetPlayerInputValues ok=" .. tostring(ok) .. (ok and "" or (" err=" .. tostring(err))))
end

-- A readable value as text, or "?" when the read fails.
local function ReadOr(f)
  local ok, v = pcall(f)
  if ok and v ~= nil then return tostring(v) end
  return "?"
end

-- One input pass (#103). The state is read before the fix. Pass 1 then calls HideLoadingScreen when the loading
-- screen is valid. Then the game-only steps and AllowPlay run. One measuring line and one watch event per pass.
-- A stale pass (the world changed, gen differs) does nothing. Returns true when the pass ran.
local function InputPass(n, gen)
  if gen ~= S.inputGen then return false end
  local t = os.time() - S.inputAt
  local pc, why = InputReady()
  if pc == nil then
    Log("input pass=" .. tostring(n) .. " skip=" .. why .. " t=" .. tostring(t))
    return false
  end
  local world = WorldObject()
  local gs = nil
  pcall(function() gs = StaticFindObject("/Script/Engine.Default__GameplayStatics") end)
  local gi = FindFirstOf("BP_OMDGameInstance_C")
  if not Valid(gi) then
    gi = nil
    if world ~= nil and gs ~= nil then
      local okG, g = pcall(function() return gs:GetGameInstance(world) end)
      if okG and Valid(g) then gi = g end
    end
  end
  local lsw = nil
  if gi ~= nil then
    local okL, w = pcall(function() return gi.LoadingScreenWidget end)
    if okL and Valid(w) then lsw = w end
  end
  local cursor = ReadOr(function() return pc.bShowMouseCursor end)
  local moveIgn = ReadOr(function() return pc:IsMoveInputIgnored() end)
  local lookIgn = ReadOr(function() return pc:IsLookInputIgnored() end)
  local loading = lsw ~= nil and "valid" or "none"
  local inVp = lsw ~= nil and ReadOr(function() return lsw:IsInViewport() end) or "?"
  local paused = gs ~= nil and ReadOr(function() return gs:IsGamePaused(pc) end) or "?"
  local hide = "skip"
  if n == 1 and lsw ~= nil then
    local okH, errH = pcall(function() gi:HideLoadingScreen() end)
    hide = okH and "ok" or "err"
    if not okH then Log("input hide err=" .. tostring(errH)) end
  end
  if Diag() then InputState("before", pc) end
  ForceGameInput(pc)
  if Diag() then InputState("after", pc) end
  AllowPlay(pc)
  Log("input pass=" .. tostring(n) .. " t=" .. tostring(t) .. " cursor=" .. cursor .. " moveIgnored=" .. moveIgn
    .. " lookIgnored=" .. lookIgn .. " loadingWidget=" .. loading .. " inViewport=" .. inVp
    .. " hide=" .. hide .. " paused=" .. paused)
  Emit("custom-map", { phase = "input", pass = n, t = t, cursor = cursor, moveIgnored = moveIgn,
    lookIgnored = lookIgn, loadingWidget = loading, inViewport = inVp, hide = hide, paused = paused })
  -- #103: the title card. The HideLoadingScreen hook is not registered in this build, so pass 2 shows it.
  -- M.OnIntroHook is once per world key, so this call does nothing on a later pass or a stock world.
  if n == 2 then M.OnIntroHook() end
  return true
end

local INPUT_WAIT_S = 15

-- Polled from WorldTick (every 2 s). Pass 1 runs at the first poll where player 0 and its pawn exist. Passes 2 and 3
-- run 2 s and 6 s after pass 1. Gives up after INPUT_WAIT_S without a controller and pawn. A world change bumps S.inputGen.
local function InputPoll()
  if not S.inputPending then return end
  local gen = S.inputGen
  local pc = InputReady()
  if pc ~= nil then
    S.inputPending = false
    if InputPass(1, gen) and ENV ~= nil and type(ENV.GameDelay) == "function" then
      ENV.GameDelay(2000, function() InputPass(2, gen) end)
      ENV.GameDelay(6000, function() InputPass(3, gen) end)
    end
  elseif os.time() - S.inputAt >= INPUT_WAIT_S then
    S.inputPending = false
    Log("input skip=timeout wait=" .. tostring(INPUT_WAIT_S))
  end
end

local function CoinTopUp()
  pcall(function()
    local pc = FindFirstOf("OMDPlayerController")
    if not pc or not pc:IsValid() then return end
    local c = tonumber(pc:GetCoin()) or 0
    if c < M.COIN_LOW then
      pc:AddCoin(M.COIN_FULL - c)
      if S.coinLogs < 20 then
        S.coinLogs = S.coinLogs + 1
        Log(string.format("coins topped up %d -> %s", c, tostring(pc:GetCoin())))
      end
    end
  end)
end

local function PawnPrint()
  if not Diag() or S.pawnPrints >= 8 then return end
  S.pawnPrints = S.pawnPrints + 1
  local pc = FindFirstOf("PlayerController")
  local pawn = pc and pc:IsValid() and pc.Pawn
  if pawn and pawn:IsValid() then
    local l = pawn:K2_GetActorLocation()
    Log(string.format("pawn loc=%.0f,%.0f,%.0f", l.X, l.Y, l.Z))
  else
    Log("pawn none")
  end
end

-- #91 M1: set the postgame screen name to the map title, then log what the widget reads back. Once per world.
local function PostgameLog()
  if S.postgame then return end
  pcall(function()
    local pg = FindFirstOf("UBP_Postgame_C")
    if pg and pg:IsValid() then
      local row = M.MAPS[S.key]
      local okSet, errSet = pcall(function() pg.LevelName:SetText(FText(row.title)) end)
      S.postgame = true
      S.retryFrom, S.retryAt = S.key, os.time()
      Log(string.format("postgame name-set ok=%s%s", tostring(okSet), okSet and "" or (" err=" .. tostring(errSet))))
      local txt = "?"
      pcall(function() txt = pg.LevelName:GetText():ToString() end)
      Log("postgame name=" .. txt)
    end
  end)
end

-- #103 phase 1: the title card. Creates the stock UBP_GenericScenarioIntro and adds it to the viewport.
-- Returns ok and a reason on failure. Nothing is written to a DataTable: the text is set with SetText on one TextBlock.
local function SetIntroText(w, key)
  pcall(function()
    if w:IsValid() then w.ScenarioName:SetText(FText(M.MAPS[key].title)) end
  end)
end

local function ShowIntro(key)
  -- #103: load the class path first (as SpawnOne does), then the package path if the class is still missing.
  local okC, errC = pcall(LoadAsset, M.INTRO_CLASS)
  local cls = StaticFindObject(M.INTRO_CLASS)
  local okW, errW = true, nil
  if cls == nil or not cls:IsValid() then
    okW, errW = pcall(LoadAsset, M.INTRO_WIDGET)
    cls = StaticFindObject(M.INTRO_CLASS)
  end
  if cls == nil or not cls:IsValid() then
    return false, "class not found after LoadAsset class ok=" .. tostring(okC) .. " " .. tostring(errC)
      .. " widget ok=" .. tostring(okW) .. " " .. tostring(errW)
  end
  local pc = FindFirstOf("OMDPlayerController")
  if pc == nil or not pc:IsValid() then return false, "no player controller" end
  local wbl = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
  local okC, w = pcall(function() return wbl:Create(pc:GetWorld(), cls, pc) end)
  if not okC then return false, "create " .. tostring(w) end
  if w == nil or not w:IsValid() then return false, "create returned no widget" end
  local okV, errV = pcall(function() w:AddToViewport(0) end)
  if not okV then return false, "viewport " .. tostring(errV) end
  if ENV ~= nil and type(ENV.GameDelay) == "function" then
    ENV.GameDelay(M.INTRO_TEXT_DELAY, function() SetIntroText(w, key) end)
  end
  return true, nil
end

-- Post-hook of BP_OMDGameInstance:HideLoadingScreen (main.lua registers it). Once per world key: S.introWorld.
-- A stock world or a stock key does nothing. Logs one line and emits one custom-map watch event per card.
function M.OnIntroHook()
  if ENV == nil then return end
  local okP, err = pcall(function()
    local worldKey, name = WorldKey()
    local key = M.MapFromWorld(name)
    if M.IntroKind(key) ~= "title" then return end
    if S.introWorld == worldKey then return end
    S.introWorld = worldKey
    local ok, why = ShowIntro(key)
    Log("intro shown map=" .. key .. " ok=" .. tostring(ok) .. (ok and "" or (" err=" .. tostring(why))))
    Emit("custom-map", { phase = "intro", map = key, ok = ok, err = why })
  end)
  if not okP then Log("intro error err=" .. tostring(err)) end
end

-- Placement status (ETrapPlacementStatusType). Diag only. Logs each change and the trap count.
local STATUS_NAMES = { [0] = "None", "NoGrid", "Valid", "Invalid", "NoCoin", "Hover", "HoverInvalid" }
local function PollPlacement()
  pcall(function()
    local pc = FindFirstOf("OMDPlayerController")
    local pawn = pc and pc:IsValid() and pc.Pawn
    if not pawn or not pawn:IsValid() then return end
    local st = tonumber(pawn.TrapPlacementStatus) or -1
    local traps = #(FindAllOf("OMDTrap") or {})
    if st ~= S.lastStatus or traps ~= S.lastTraps then
      S.lastStatus, S.lastTraps = st, traps
      local l = pawn:K2_GetActorLocation()
      local eq = "?"
      pcall(function() eq = pawn:GetEquippedItem():GetFName():ToString() end)
      Log(string.format("placement status=%d(%s) traps=%d equipped=%s pawn=%.0f,%.0f,%.0f",
        st, STATUS_NAMES[st] or "?", traps, eq, l.X, l.Y, l.Z))
    end
  end)
end

-- Trap hook logs. Diag only. Registered once, the first time a Test map is seen with Diag on.
local function RegisterDiagHooks()
  if S.hooks then return end
  S.hooks = true
  for _, h in ipairs(M.DIAG_HOOKS) do
    local label = h[2]
    local ok, err = pcall(RegisterHook, h[1], function(ctx, a1)
      local extra = ""
      pcall(function() local v = a1 and a1:get(); if v ~= nil then extra = " arg=" .. (type(v) == "userdata" and v.GetFullName and v:GetFullName() or tostring(v)) end end)
      Log("hook " .. label .. extra)
    end)
    Log("hook-register " .. label .. " ok=" .. tostring(ok) .. (ok and "" or (" err=" .. tostring(err))))
  end
end

-- Enemy routes (#97 M3, "stock"). Each new enemy pawn with a controller gets LoadPathFromLevel() and, when the map
-- has a start point, SetStartPoint(start). The controller is not swapped. SetStartPoint is never called with nil.
local function PathOrcs()
  -- All start points, with their 2D location (#98 M2). A pawn takes the nearest one.
  local starts = {}
  for _, pt in ipairs(FindAllOf("OMDPathPoint") or {}) do
    local ok, isStart = pcall(function() return pt.bIsStartPoint end)
    if ok and isStart == true then
      local okP, l = pcall(function() return pt:K2_GetActorLocation() end)
      if okP and l then starts[#starts + 1] = { x = l.X, y = l.Y, pt = pt } end
    end
  end
  for _, pawn in ipairs(FindAllOf("OMDAICharacter") or {}) do
    pcall(function()
      if not pawn:IsValid() then return end
      local name = pawn:GetFName():ToString()
      if name:find("Wisp") or S.walkDone[name] then return end
      local c = pawn.Controller
      if not c or not c:IsValid() then return end
      S.walkDone[name] = true
      local okL, eL = pcall(function() c:LoadPathFromLevel() end)
      local idx = nil
      local okPos, pl = pcall(function() return pawn:K2_GetActorLocation() end)
      if okPos and pl and #starts > 0 then idx = M.NearestStart(starts, pl.X, pl.Y) end
      local okS, eS = false, "no start point"
      if idx then okS, eS = pcall(function() c:SetStartPoint(starts[idx].pt) end) end
      -- #70: 20 pathstart lines per world, then one capped line.
      if S.pathLogs < 20 then
        S.pathLogs = S.pathLogs + 1
        Log(string.format("pathstart %s load=%s start=%s%s start_index=%s", name, tostring(okL), tostring(okS),
          (okL and okS) and "" or (" err=" .. tostring(eL or eS)), tostring(idx)))
      elseif not S.pathCapped then
        S.pathCapped = true
        Log("pathstart log capped")
      end
    end)
  end
end

-- Enemy routes ("walk"): the engine AIController walks each pawn to the Rift. An enemy within RIFT_REACH is handed to
-- OnRiftEntered (the coordinator), or removed when that call fails.
local function RiftLocation()
  local r = FindFirstOf("OMDRift")
  if r and r:IsValid() then return r:K2_GetActorLocation() end
  return nil
end

local function WalkOrcs()
  local rift = RiftLocation()
  if not rift then return end
  local gs = StaticFindObject("/Script/Engine.Default__GameplayStatics")
  local aiClass = StaticFindObject("/Script/AIModule.AIController")
  for _, pawn in ipairs(FindAllOf("OMDAICharacter") or {}) do
    pcall(function()
      if not pawn:IsValid() then return end
      local name = pawn:GetFName():ToString()
      if name:find("Wisp") then return end
      if S.walkDone[name] then return end
      local l = pawn:K2_GetActorLocation()
      if l.X == 0 and l.Y == 0 and l.Z == 0 then return end
      local dx, dy = l.X - rift.X, l.Y - rift.Y
      if dx * dx + dy * dy < M.RIFT_REACH * M.RIFT_REACH then
        local entered, callErr = false, nil
        local coord = FindFirstOf("OMDOnslaughtCoordinator")
        if coord and coord:IsValid() then
          local okE, errE = pcall(function() coord:OnRiftEntered(pawn, { X = l.X, Y = l.Y, Z = l.Z }) end)
          entered = okE
          if not okE then callErr = tostring(errE) end
        end
        if entered then
          local rp = "?"
          pcall(function()
            local v = FindFirstOf("OMDGameState").RiftPoints
            if v ~= nil then rp = tostring(v) end
          end)
          Log(string.format("walk rift-entered %s at %.0f,%.0f,%.0f rift=%s", name, l.X, l.Y, l.Z, rp))
          S.walkers[name] = nil
          S.walkDone[name] = true
          return
        end
        local errText = callErr and (" err=" .. callErr) or ""
        Log(string.format("walk reached-rift %s at %.0f,%.0f,%.0f%s", name, l.X, l.Y, l.Z, errText))
        pawn:K2_DestroyActor()
        S.walkers[name] = nil
        S.walkDone[name] = true
        return
      end
      if S.walkers[name] then return end
      local tf = { Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = { X = l.X, Y = l.Y, Z = l.Z }, Scale3D = { X = 1, Y = 1, Z = 1 } }
      local ctrl = gs:BeginDeferredActorSpawnFromClass(pawn, aiClass, tf, 1, nil)
      gs:FinishSpawningActor(ctrl, tf)
      local old = pawn.Controller
      if old and old:IsValid() then pcall(function() old:UnPossess() end) end
      ctrl:Possess(pawn)
      local res = ctrl:MoveToLocation({ X = rift.X, Y = rift.Y, Z = l.Z }, 50, false, false, false, true, nil, true)
      S.walkers[name] = ctrl
      if S.walkLogs < 30 then
        S.walkLogs = S.walkLogs + 1
        Log(string.format("walk start %s from %.0f,%.0f,%.0f to rift %.0f,%.0f result=%s oldCtrl=%s",
          name, l.X, l.Y, l.Z, rift.X, rift.Y, tostring(res), old and old:IsValid() and old:GetClass():GetFName():ToString() or "none"))
      end
    end)
  end
end

-- Battle music. Off (M.MUSIC_ENABLED). The code stays so a later test can turn it on.
local function StartMusic(coord)
  local firstErr = nil
  local function Try(f)
    local ok, e = pcall(f)
    if not ok and firstErr == nil then firstErr = tostring(e) end
    return ok
  end
  local variant = math.random(0, 2)
  local comp
  local cuePath = M.MUSIC_CUE_PATH .. "." .. M.MUSIC_CUE_PATH:match("([^/]+)$")
  local okSpawn = Try(function()
    pcall(LoadAsset, cuePath)
    local cue = StaticFindObject(cuePath)
    if not cue or not cue:IsValid() then error("cue not found", 0) end
    local gs = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    comp = gs:SpawnSound2D(coord, cue, 1.0, 1.0, 0.0, nil, false, false)
    if not comp or not comp:IsValid() then error("SpawnSound2D returned no component", 0) end
  end)
  if okSpawn then S.musicComp = comp end
  local okVar = okSpawn and Try(function() comp:SetIntParameter("BattleMusicVariant", variant) end)
  local okX = okSpawn and Try(function() comp:SetFloatParameter("BattleXfade", 0) end)
  local ok = okSpawn and okVar and okX
  Log(string.format("music start ok=%s variant=%d%s", tostring(ok), variant, firstErr and (" err=" .. firstErr) or ""))
end

local function MusicTick()
  if not M.MUSIC_ENABLED then return end
  local flag
  local okF = pcall(function()
    local gs = FindFirstOf("OMDGameState")
    if not gs or not gs:IsValid() then error("no game state", 0) end
    flag = gs.bIsGoBreakActive == true
  end)
  if not okF or flag == nil then return end
  if S.musicComp == nil then
    if flag or S.musicAttempts >= M.MUSIC_START_MAX then return end
    local coord = FindFirstOf("OMDOnslaughtCoordinator")
    if not coord or not coord:IsValid() then return end
    S.musicAttempts = S.musicAttempts + 1
    StartMusic(coord)
    if S.musicComp then S.musicFlag = false end
    return
  end
  if flag ~= S.musicFlag then
    local v = flag and 1 or 0
    local okX, errX = pcall(function() S.musicComp:SetFloatParameter("BattleXfade", v) end)
    S.musicFlag = flag
    Log("music xfade=" .. v .. (okX and "" or (" err=" .. tostring(errX))))
  end
end

-- #103 C1: the gate doors of the custom world (BP_Door_Exterior_2W). Valid actors only, one per full name.
local function GateDoors()
  local out, seen = {}, {}
  for _, cls in ipairs({ "OMDDoor", "BP_Door_Exterior_2W_C" }) do
    local okF, found = pcall(FindAllOf, cls)
    for _, d in ipairs((okF and found) or {}) do
      local okN, full = pcall(function() return d:GetFullName() end)
      if okN and type(full) == "string" and full:find("BP_Door_Exterior_2W", 1, true) and not seen[full] then
        seen[full] = true
        local okV, valid = pcall(function() return d:IsValid() end)
        if okV and valid == true then out[#out + 1] = d end
      end
    end
  end
  return out
end

-- #103 C1: the door number is the indexInLevel of the nearest OMDAISpawner (3D distance). nil when it cannot be read.
local function SpawnerNumber(door)
  local okL, here = pcall(function() return door:K2_GetActorLocation() end)
  if not okL or here == nil then return nil end
  local best, bestD = nil, nil
  local okS, spawners = pcall(FindAllOf, "OMDAISpawner")
  for _, sp in ipairs((okS and spawners) or {}) do
    pcall(function()
      local p = sp:K2_GetActorLocation()
      local idx = sp.indexInLevel
      local dx, dy, dz = p.X - here.X, p.Y - here.Y, p.Z - here.Z
      local dd = dx * dx + dy * dy + dz * dz
      if idx ~= nil and (bestD == nil or dd < bestD) then best, bestD = idx, dd end
    end)
  end
  return best
end

-- #103: plays one door cue (LoadAsset, then a 2D sound with the player controller as world context) and logs it.
-- Steps: find, gs, pc, play. A failed step names itself in err=. The play step calls PlaySound2D with 8 arguments
-- (UE 4.27 signature). No SpawnSound2D: it crashed UE4SS 83330635 (see the music note at the top of this file).
local function PlayDoorCue(name, i, hp)
  local base = "DX_OMD3_Announcer_Door_" .. name .. "_SC"
  local path = "/Game/Sounds/Dialogue/Announcer/Cue/" .. base .. "." .. base
  local step = "find"
  local ok, res = pcall(function()
    local okL, errL = pcall(LoadAsset, path)   -- a failed load is only the reason text, as in SpawnOne
    local cue = StaticFindObject(path)
    if not cue or not cue:IsValid() then error("cue not found after LoadAsset ok=" .. tostring(okL) .. " " .. tostring(errL), 0) end
    step = "gs"
    local gs = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    if not gs then error("no GameplayStatics", 0) end
    step = "pc"
    local pc = PlayerCtl(WorldObject())
    if pc == nil then error("no player controller", 0) end
    step = "play"
    -- WorldContextObject, Sound, VolumeMultiplier, PitchMultiplier, StartTime, ConcurrencySettings, OwningActor, bIsUISound
    gs:PlaySound2D(pc, cue, 1.0, 1.0, 0.0, nil, nil, true)
    return "PlaySound2D"
  end)
  if ok then
    Log(string.format("door-cue door=%s cue=%s hp=%s ok=true via=%s", tostring(i), name, tostring(hp), tostring(res)))
  else
    Log(string.format("door-cue door=%s cue=%s hp=%s ok=false err=%s: %s", tostring(i), name, tostring(hp), step, tostring(res)))
  end
end

-- #103 C1: the door poll (every 0.5 s, custom worlds only). S.doorTicks counts the polls of this world.
local function DoorTick()
  if S.key == nil then return end
  S.doorTicks = S.doorTicks + 1
  local now = S.doorTicks * 0.5
  for _, d in ipairs(GateDoors()) do
    local okN, full = pcall(function() return d:GetFullName() end)
    if okN and type(full) == "string" then
      local st = S.doors[full]
      if st == nil then
        st = { i = SpawnerNumber(d) }
        S.doors[full] = st
      end
      local hp, open = nil, nil
      pcall(function() hp = d.Health end)
      pcall(function() open = d.bIsOpen end)
      if type(hp) ~= "number" then hp = nil end
      if type(open) ~= "boolean" then open = nil end
      local cue, delay = M.DoorCue(st, st.i or 0, now, hp, open)
      if cue ~= nil then
        local wk, i, h = S.worldKey, st.i or 0, hp
        if delay > 0 then
          ENV.GameDelay(math.floor(delay * 1000), function()
            if S.worldKey == wk then PlayDoorCue(cue, i, h) end  -- a cue from an old world does nothing
          end)
        else
          PlayDoorCue(cue, i, h)
        end
      end
    end
  end
end

-- Resets the per-world state. Called on each world change.
local function ResetWorld(worldKey, name, key)
  S.worldKey, S.world, S.key = worldKey, name, key
  S.musicComp, S.musicFlag, S.musicAttempts = nil, nil, 0
  S.postgame = false
  S.pawnPrints = 0
  S.walkers, S.walkDone = {}, {}
  S.lastStatus, S.lastTraps = nil, nil
  -- #70: the error and pathstart caps are per world.
  S.errLogs = 0
  S.pathLogs, S.pathCapped = 0, false
  S.doors, S.doorTicks = {}, 0  -- #103 C1: the gate door state starts over on a new world
  S.inputGen = S.inputGen + 1  -- #103: pending input passes of the old world do nothing
  S.inputPending = false
end

local function WorldTick()
  local worldKey, name = WorldKey()
  if worldKey ~= S.worldKey then
    local key = M.MapFromWorld(name)
    -- The retry source is read once here and cleared on every world change, so a later stock play is not redirected.
    local retryFrom, retryAt = S.retryFrom, S.retryAt
    S.retryFrom, S.retryAt = nil, nil
    ResetWorld(worldKey, name, key)
    if key ~= nil then
      Log("world " .. name .. " key=" .. worldKey)
      SpawnAll(key)
      S.inputPending, S.inputAt = true, os.time()  -- #103: the input passes start at the first valid pawn (InputPoll)
    elseif retryFrom ~= nil then
      local t = M.RetryTarget(retryFrom, M.ShortName(name), os.time() - retryAt)
      if t ~= nil then
        Log("retry reopen map=" .. t)
        -- The borrowed map loads first. The launch runs 3 s later on the game thread.
        ENV.GameDelay(3000, function() M.Launch(t) end)
      end
    end
  end
  if S.key == nil then return end
  InputPoll()
  if Diag() then RegisterDiagHooks() end
  if CoinOn() then CoinTopUp() end
  PawnPrint()
  PostgameLog()
  MusicTick()
end

-- Launch (#93 M2): the mission borrow, then "open <key>" through env.ConsoleExec (the cvar path). Returns ok.
-- A failed borrow does not open the map: the end-of-match code reads the mission with no null check.
-- Called on the game thread by F8 (Endless hub only) and by the custom-map-launch command.
function M.Launch(name)
  local key = M.LaunchKey(name)
  if key == nil then
    Log("launch map=" .. tostring(name) .. " ok=false err=unknown map")
    return false
  end
  if ENV == nil then
    Log("launch map=" .. key .. " ok=false err=module not started")
    return false
  end
  if not BorrowMission(key) then
    Log("launch map=" .. key .. " ok=false err=borrow")
    return false
  end
  local okRun, errText = false, "no ConsoleExec"
  if type(ENV.ConsoleExec) == "function" then okRun, errText = ENV.ConsoleExec("open " .. key) end
  local ok = okRun == true
  Log("launch map=" .. key .. " ok=" .. tostring(ok) .. (ok and "" or (" err=" .. tostring(errText))))
  return ok
end

local function FastTick()
  -- F8 sets the flag on another thread. Only the Endless hub launches; any other screen does nothing.
  if S.f8 then
    S.f8 = false
    if ENV and type(ENV.HubOpen) == "function" and ENV.HubOpen() then M.Launch(nil) end
  end
  if S.key == nil then return end
  if Diag() then PollPlacement() end
  local mode = M.MAPS[S.key].enemyPath
  if mode == "walk" then WalkOrcs() elseif mode == "stock" then PathOrcs() end
end

-- Registers the two game-thread loops. Runs once from main.lua. Does nothing on a world not in M.MAPS.
function M.Start(env)
  ENV = env
  env.GameLoop(2000, Guard("world", WorldTick))
  env.GameLoop(300, Guard("fast", FastTick))
  env.GameLoop(500, Guard("doors", DoorTick))  -- #103 C1: the gate door cues
  -- F8 (#93 M2). The key callback runs on another thread: it only sets the flag that FastTick reads.
  if type(env.RegisterKeyBind) == "function" and type(env.Key) == "table" then
    local okK, errK = pcall(env.RegisterKeyBind, env.Key.F8, function() S.f8 = true end)
    if not okK then Log("key bind F8 failed err=" .. tostring(errK)) end
  end
  return true
end

return M
