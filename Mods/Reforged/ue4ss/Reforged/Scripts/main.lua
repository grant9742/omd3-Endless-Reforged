-- Focused spawn probe for Reforged.
-- BEGIN game-thread compatibility
-- UE4SS ran LoopAsync and ExecuteWithDelay callbacks on its async thread. Their ExecuteInGameThread hops raced with the
-- game-thread hooks and lost callbacks ("Ref was not function"). These helpers run every mod callback on the game thread.
-- Builds without the in-game-thread timers take the fallback path.
GT_ON_THREAD = GT_ON_THREAD or false

-- Runs fn with GT_ON_THREAD set and returns fn's first result. An error is printed. The flag is restored either way.
function GameRun(label, fn)
  local prev = GT_ON_THREAD
  GT_ON_THREAD = true
  local ok, res = pcall(fn)
  GT_ON_THREAD = prev
  if not ok then
    print("[Reforged] game-thread error label=" .. tostring(label) .. " err=" .. tostring(res))
    return nil
  end
  return res
end

-- Calls fn on the game thread every ms milliseconds. fn returns true to stop the loop.
function GameLoop(ms, fn)
  if type(LoopInGameThreadWithDelay) == "function" then
    local handle
    handle = LoopInGameThreadWithDelay(ms, function()
      if GameRun("loop", fn) == true then CancelDelayedAction(handle) end
    end)
    return handle
  end
  -- Fallback. The stop value is seen only when the game-thread hop runs at once (the offline harness).
  return LoopAsync(ms, function()
    local stop
    ExecuteInGameThread(function() stop = GameRun("loop", fn) end)
    return stop == true
  end)
end

-- Calls fn once on the game thread after ms milliseconds.
function GameDelay(ms, fn)
  if type(ExecuteInGameThreadWithDelay) == "function" then
    return ExecuteInGameThreadWithDelay(ms, function() GameRun("delay", fn) end)
  end
  return ExecuteWithDelay(ms, function() ExecuteInGameThread(function() GameRun("delay", fn) end) end)
end

-- Runs fn now when the caller is on the game thread. Otherwise it queues fn (RunOnGameThread).
function GameNow(fn)
  if GT_ON_THREAD then
    fn()
    return
  end
  RunOnGameThread("now", fn)
end
-- END game-thread compatibility

-- Wisp spawn effects are excluded from class counts.

-- Registers a UFunction hook only when the function exists. A RegisterHook call on a missing
-- function raised inside UE4SS, and later crashes followed in UE4SS.dll. Returns the pcall results of RegisterHook.
function SafeRegisterHook(name, pre, post)
  local function Reg(...) return RegisterHook(...) end
  if type(StaticFindObject) ~= "function" then
    if post == nil then return pcall(Reg, name, pre) end
    return pcall(Reg, name, pre, post)
  end
  local okF, fn = pcall(StaticFindObject, name)
  if not okF then
    print("[Reforged] hook lookup failed for " .. name .. ", registering anyway")
  else
    local okV, valid = pcall(function() return fn ~= nil and fn:IsValid() end)
    if not (okV and valid) then
      print("[Reforged] hook skipped: no such function " .. name)
      return false, "missing function " .. name
    end
  end
  if post == nil then return pcall(Reg, name, pre) end
  return pcall(Reg, name, pre, post)
end

-- TESTING is off for normal play. `testing on` turns on the developer features: the rift keeper (it runs only after `rift-target <n>`, not on `testing on`),
-- Go Breaks off at map ready, Feign Death at round start, the diagnostic hooks (DIAG) and the developer commands (DEV_OPS).
TESTING = false
DIAG = {} -- diagnostic hook registrations; each runs once, the first time `testing on` is sent
DIAG_STARTED = false
RIFT_TARGET = nil -- nil = do not maintain RiftPoints
-- Test mode. F7 in the Endless hub sets TEST_MODE. TESTING_LIGHT is test mode without the full testing features:
-- no Feign Death at round start and no diagnostic hooks (DiagOn). `testing on` clears TESTING_LIGHT.
TEST_MODE = false
TESTING_LIGHT = false
function DiagOn() return TESTING == true and TESTING_LIGHT ~= true end
BT_PROBE_ALLOW_LOAD = false -- `bt-probe-load on|off`. A tree LoadAsset crashed under UE4SS 3.0.1; off by default.
local TESTING_SAVED_RIFT = nil
local PROTOS = {
  { name = "WraithBoss", guid = { A = -1789559968, B = 1146684538, C = -1184985469, D = -362088363 } },
  { name = "OgreBasher", guid = { A = -994092372, B = 1190903844, C = 1978333605, D = -1629347413 } },
  { name = "OrcBoss", guid = { A = -2147346724, B = 1083948173, C = -141651831, D = -1764342275 } },
  { name = "KoboldKing", guid = { A = -832488394, B = 1332548544, C = -928898927, D = 1209538583 } },
  { name = "OrcLight", guid = { A = -1099305080, B = 1287038301, C = 97048455, D = 766713896 } },
  { name = "OrcMedium", guid = { A = -363453412, B = 1277161899, C = 1313412481, D = 379883271 } },
  { name = "OrcHeavy", guid = { A = -1223220373, B = 1291908304, C = 685939604, D = -125075422 } },
  { name = "OrcArcher", guid = { A = -49827199, B = 1243384847, C = 1733597578, D = 1751683791 } },
  { name = "OrcArcherTNT", guid = { A = -1353993883, B = 1211719993, C = 589469367, D = 1232075005 } },
  { name = "Kobold", guid = { A = -866211269, B = 1268044001, C = 64649878, D = -511574880 } },
  { name = "KoboldTNT", guid = { A = 1061176994, B = 1209609950, C = -2118578017, D = -51801459 } },
  { name = "Ogre", guid = { A = -1007471419, B = 1258484120, C = 30646930, D = 527792864 } },
  { name = "OgreArmored", guid = { A = 1571215822, B = 1290523976, C = 1716816825, D = -134857778 } },
  { name = "OgreMoneybags", guid = { A = 1668500294, B = 1225575173, C = 1177930932, D = 188556940 } },
  { name = "Troll", guid = { A = -528145464, B = 1330800651, C = 429724549, D = -1749173083 } },
  { name = "TrollMountain", guid = { A = -1439548990, B = 1181170814, C = -2111901006, D = -2091707243 } },
  { name = "ElementalEarthling", guid = { A = 1905517867, B = 1157931156, C = -643470711, D = -89552545 } },
  { name = "ElementalEarth", guid = { A = 570868827, B = 1176519053, C = -869451130, D = -1224374685 } },
  { name = "ElementalEarthLord", guid = { A = -1329985855, B = 1272423898, C = 1845759872, D = 662299013 } },
  { name = "ElementalFireling", guid = { A = -568627947, B = 1173896475, C = -532645716, D = -1899960163 } },
  { name = "ElementalFire", guid = { A = 2094933082, B = 1256638481, C = -2099673980, D = -1619172083 } },
  { name = "ElementalFireLord", guid = { A = 2003039420, B = 1127756505, C = 903143813, D = -1103411880 } },
  { name = "WraithHealer", guid = { A = 1967658654, B = 1174014949, C = 56683421, D = -287262424 } },
  { name = "FireFiendLight", guid = { A = -1121377935, B = 1244496873, C = 554592440, D = -1127417737 } },
  { name = "FireFiendMedium", guid = { A = -948757954, B = 1090324709, C = 403823496, D = -2027286368 } },
  { name = "FireFiendHeavy", guid = { A = 1482850861, B = 1228849976, C = 971454900, D = -1680815771 } },
  { name = "FireFiendRunner", guid = { A = 614867905, B = 1304164447, C = 718454688, D = 1132286467 } },
  { name = "FireFiendMage", guid = { A = -1271393139, B = 1121983458, C = -277318729, D = 961921656 } },
  { name = "FireFiendOverlord", guid = { A = 1044865507, B = 1138212610, C = 2057490063, D = 600196967 } },
  { name = "GnollAssassin", guid = { A = 770315087, B = 1319484270, C = 822188217, D = -2003336549 } },
  { name = "GnollGrenadier", guid = { A = 52224101, B = 1227552265, C = 1690674111, D = -912397333 } },
  { name = "CyclopsMedium", guid = { A = -526110860, B = 1164916390, C = 1732210575, D = 29279440 } },
  { name = "CyclopsHeavy", guid = { A = -1565826048, B = 1143823884, C = -1267827584, D = 1287514985 } },
  { name = "CyclopsMage", guid = { A = -142797793, B = 1154323509, C = -344718179, D = -1556713335 } },
  { name = "CyclopsMesmerizer", guid = { A = 1058862871, B = 1148430717, C = 554857406, D = 397059495 } },
  { name = "CyclopsShaman", guid = { A = 593189175, B = 1338266056, C = 1364544660, D = -1752295868 } },
  { name = "HellbatFire", guid = { A = 1931987178, B = 1316624954, C = 638890928, D = -1166599943 } },
  { name = "HellbatBaby", guid = { A = 266012415, B = 1087690483, C = -1780078674, D = 148142129 } },
  { name = "HellbatIce", guid = { A = 992011133, B = 1309115564, C = -1736606808, D = 1547489298 } },
  { name = "HellbatLigtning", guid = { A = -630476962, B = 1140292473, C = -1512490840, D = -1978835633 } },
  { name = "HellbatBile", guid = { A = 859420825, B = 1244804960, C = 1352959139, D = 515678931 } },
  { name = "HellbatArcane", guid = { A = 1806877732, B = 1208416481, C = -1449500237, D = 2000976545 } },
  { name = "HellbatBoss", guid = { A = 664737126, B = 1086244113, C = 1056713659, D = -1755291754 } },
  { name = "LizardmanLight", guid = { A = 536753008, B = 1246298361, C = -820970096, D = 1714802148 } },
  { name = "LizardmanHeavy", guid = { A = 592723524, B = 1191210845, C = -1572169847, D = 11487875 } },
  { name = "LizardmanRanger", guid = { A = -1634549265, B = 1228783989, C = -1278171495, D = 1769575084 } },
  { name = "LizardmanAssassin", guid = { A = -2005065317, B = 1172737608, C = 1286176422, D = 1987900760 } },
  { name = "WraithBoss_Scramble", guid = { A = -1800640294, B = 1098996045, C = 21306815, D = 696149242 } },
  { name = "OgreBasher_Scramble", guid = { A = -1317404817, B = 1132596802, C = 525230225, D = -1269827519 } },
  { name = "OrcBoss_Scramble", guid = { A = 1206576365, B = 1239807143, C = 2052652700, D = -1672425536 } },
  { name = "KoboldKing_Scramble", guid = { A = -1029605510, B = 1287944526, C = -349892720, D = -908630390 } },
}

math.randomseed(os.time())
DM_STOCK = {} -- original value of each difficulty manager field, filled by dm-set and by BreaksOff, read back by `dm-set <field> stock`
-- Hook entry trace. Counts calls per hook name. Logs the first 5 calls of each name after each map load.
-- HookTrace reads only its name argument; it never touches a hook argument. `hook-trace on|off` sets HOOK_TRACE_ON.
if HOOK_TRACE_ON == nil then HOOK_TRACE_ON = true end
HOOK_TRACE = {}
local function HookTrace(name)
  if not HOOK_TRACE_ON then return end
  local n = (HOOK_TRACE[name] or 0) + 1
  HOOK_TRACE[name] = n
  if n <= 5 then print("[Reforged] hook-enter " .. name .. " #" .. n) end
end
local function coordinator()
  local ok, c = pcall(FindFirstOf, "OMDOnslaughtCoordinator")
  if ok and c and c:IsValid() then return c end
  return nil
end
local function population(c)
  local function get(name)
    local ok, n = pcall(function() return c[name](c) end)
    return ok and tostring(n) or "?"
  end
  return string.format("alive=%s waiting=%s approved=%s",
    get("GetNumPawnsAlive"), get("GetNumPawnsWaitingForSpawn"), get("GetNumPawnsApprovedForSpawn"))
end
-- SetAllAICharactersAmount (0x140fb6790) crashed OMD in 4 of 5 live calls: access violation, null +0x10,
-- RVA 0xfb6b2b. The function looks up the coordinator's current group key (+0x3c4) in a hash map (+0x370),
-- gets null when the key is missing, and reads piVar9[4] with no null check. Crashes came between rounds,
-- 10 s into a round and 46 s into a round. The one success was at the first round of a match.
-- SetAllAICharactersClass (0x140fb6c10) walks the same queue and is blocked as well.
-- Set true only to retest. Use `wave <count>` (door spawns) to control wave size instead.
ALLOW_NATIVE_QUEUE_EDIT = false
local function RoundActive(c)
  return ALLOW_NATIVE_QUEUE_EDIT == true
end
local function setRift(reason)
  ExecuteInGameThread(function()
    local c = coordinator()
    if not c then print("[Reforged] rift: coordinator unavailable (" .. reason .. ")"); return end
    local before = c.RiftPoints
    if RIFT_TARGET == nil or before == RIFT_TARGET then return end
    local ok, err = pcall(function() c.RiftPoints = RIFT_TARGET end)
    print(string.format("[Reforged] rift (%s): %s -> %s, set=%s, readback=%s",
      reason, tostring(before), tostring(RIFT_TARGET), ok and "ok" or tostring(err), tostring(c.RiftPoints)))
  end)
end

-- Keeper; only writes when the game has changed the value. 500 ms, not 3 s: the level starts at 20 RiftPoints.
GameLoop(500, function()
  if RIFT_TARGET == nil then return false end
  local c = coordinator()
  -- The HUD reads OMDGameState.RiftPoints, so hold that too (the coordinator value alone left the HUD falling).
  local okG, gs = pcall(FindFirstOf, "OMDGameState")
  if okG and gs and gs:IsValid() and RIFT_TARGET ~= nil then
    local okR, cur = pcall(function() return gs.RiftPoints end)
    if okR and cur ~= RIFT_TARGET then
      local okW, errW = pcall(function() gs.RiftPoints = RIFT_TARGET end)
      print(string.format("[Reforged] rift (maintain game state): %s -> %s set=%s err=%s", tostring(cur), tostring(RIFT_TARGET), tostring(okW), okW and "-" or tostring(errW)))
    end
  end
  if c and RIFT_TARGET ~= nil and c.RiftPoints ~= RIFT_TARGET then
    local before = c.RiftPoints
    local ok, err = pcall(function() c.RiftPoints = RIFT_TARGET end)
    print(string.format("[Reforged] rift (maintain): %s -> %s, set=%s, readback=%s",
      tostring(before), tostring(RIFT_TARGET), ok and "ok" or tostring(err), tostring(c.RiftPoints)))
  end
  return false
end)

local PROTO_BY_NAME = {}
for _, row in ipairs(PROTOS) do PROTO_BY_NAME[row.name] = row end
-- "LootGoblin" is the Kobold proto with a flag. A pawn spawned from it is registered as a loot goblin (see GoblinTick).
do
  local k = PROTO_BY_NAME["Kobold"]
  local g = {}
  for key, v in pairs(k) do g[key] = v end
  g.lootGoblin = true
  PROTO_BY_NAME["LootGoblin"] = g
end

local callId, spawnBusy = 0, false
local function classCounts()
  local counts = {}
  local ok, list = pcall(FindAllOf, "OMDAIController")
  if not ok or not list then return counts end
  for _, c in ipairs(list) do
    pcall(function()
      if not c:IsValid() or not c.Pawn or not c.Pawn:IsValid() then return end
      local full = c.Pawn:GetFullName()
      if full:find("BP_Wisp_") then return end
      local name = full:match("(BP_[%w_]+)_C_%d+")
      if name then counts[name] = (counts[name] or 0) + 1 end
    end)
  end
  return counts
end
local function formatCounts(counts)
  local parts = {}
  for name, n in pairs(counts) do parts[#parts + 1] = name .. "=" .. tostring(n) end
  table.sort(parts)
  return #parts > 0 and table.concat(parts, ",") or "no non-Wisp controllers"
end
local function formatDelta(before, after)
  local names, parts = {}, {}
  for name in pairs(before) do names[name] = true end
  for name in pairs(after) do names[name] = true end
  for name in pairs(names) do
    local delta = (after[name] or 0) - (before[name] or 0)
    if delta ~= 0 then parts[#parts + 1] = name .. string.format("%+d", delta) end
  end
  table.sort(parts)
  return #parts > 0 and table.concat(parts, ",") or "no class-count change"
end

-- Release the Hoard gate: no director spawn before the player presses G (Release the Hoard).
-- GameState.bIsGoBreakActive is true in the build phase and in a Go Break. `hoard-gate off` turns the gate off.
if HOARD_GATE == nil then HOARD_GATE = true end
HOARD_HELD = {}
-- Returns true when the hoard is released. Otherwise returns false and the reason: "build-phase" or "no-game-state".
function HoardReleased()
  local ok, result = pcall(function()
    local gs = FindFirstOf("OMDGameState")
    if not gs or not gs:IsValid() then return "no-game-state" end
    local okB, active = pcall(function() return gs.bIsGoBreakActive end)
    if not okB or active == nil then return "no-game-state" end
    if active then return "build-phase" end
    return true
  end)
  if not ok then return false, "no-game-state" end
  if result == true then return true, "released" end
  return false, result
end
-- Holds a spawn call while the gate is on and the hoard is not released. repeatCall runs the same call again on release.
local function HoardHold(what, repeatCall)
  if HOARD_GATE ~= true then return false end
  local released, reason = HoardReleased()
  if released then return false end
  HOARD_HELD[#HOARD_HELD + 1] = repeatCall
  print(string.format("[Reforged] spawn held: %s (Release the Hoard not pressed) held=%d what=%s", reason, #HOARD_HELD, what))
  return true
end

local function RequestSpawnBatch(entries, source)
  do
    local parts = {}
    for _, entry in ipairs(entries) do parts[#parts + 1] = (entry.row and entry.row.name or "?") .. "x" .. tostring(entry.count) end
    if HoardHold("batch " .. table.concat(parts, ","), function() RequestSpawnBatch(entries, source) end) then return end
  end
  if spawnBusy then
    print("[Reforged] director ignored " .. source .. ": prior spawn sample still running")
    return
  end
  local total = 0
  local labels = {}
  for _, entry in ipairs(entries) do
    entry.count = math.max(1, math.min(100, math.floor(tonumber(entry.count) or 1)))
    total = total + entry.count
    labels[#labels + 1] = entry.row.name .. "x" .. tostring(entry.count)
  end
  if total > 100 then
    print("[Reforged] director rejected " .. source .. ": batch total exceeds 100")
    return
  end
  spawnBusy = true
  callId = callId + 1
  local id = callId
  local request = table.concat(labels, ",")
  print(string.format("[Reforged] director #%d received source=%s request=%s", id, source, request))
  ExecuteInGameThread(function()
    local c = coordinator()
    if not c then
      print("[Reforged] director #" .. id .. " aborted: no coordinator")
      spawnBusy = false
      return
    end
    local beforePopulation = population(c)
    local beforeClasses = classCounts()
    -- Start a group with zero delay before queuing. SpawnEntities only enqueues;
    -- the 2026-10-11 on-demand spawn test spawned only after this call.
    local okGroup, errGroup = pcall(function() c:OnslaughtStartGroup(0.0) end)
    print(string.format("[Reforged] director #%d start-group ok=%s err=%s", id, tostring(okGroup), tostring(errGroup)))
    local results = {}
    for _, entry in ipairs(entries) do
      local ok, err = pcall(function()
        c:OnslaughtSpawnEntities({ Guid = entry.row.guid }, entry.count, false, 0, 0.0, 5)
      end)
      results[#results + 1] = entry.row.name .. "=" .. (ok and "ok" or tostring(err))
    end
    print(string.format("[Reforged] director #%d queued request=%s calls=%s before={%s} after-call={%s}",
      id, request, table.concat(results, ","), beforePopulation, population(c)))
    local samples = 0
    GameLoop(2000, function()
      samples = samples + 1
      local now = coordinator()
      local suffix = "class sample pending"
      if samples == 3 then
        local ok, afterClasses = pcall(classCounts)
        suffix = ok and ("class delta=" .. formatDelta(beforeClasses, afterClasses) ..
          " snapshot=" .. formatCounts(afterClasses)) or ("class sample error=" .. tostring(afterClasses))
      end
      print(string.format("[Reforged] director #%d +%ds %s %s", id, samples * 2,
        now and population(now) or "no coordinator", suffix))
      if samples >= 5 then spawnBusy = false; return true end
      return false
    end)
  end)
end

local function RequestSpawn(row, count, source)
  RequestSpawnBatch({ { row = row, count = count } }, source)
end

local function SetWaveAmount(value)
  local amount = math.max(1, math.min(100, math.floor(tonumber(value) or 0)))
  ExecuteInGameThread(function()
    local c = coordinator()
    if not c then print("[Reforged] wave-amount aborted: no coordinator"); return end
    if not RoundActive(c) then print("[Reforged] wave-amount rejected: native SetAllAICharactersAmount crashes OMD (4 of 5 calls). Use wave <count>"); return end
    local ok, err = pcall(function() c:SetAllAICharactersAmount(amount) end)
    print(string.format("[Reforged] wave-amount each-pending-command=%d call=%s", amount,
      ok and "ok" or tostring(err)))
  end)
end

local function SetWaveClass(name)
  local row = PROTO_BY_NAME[name]
  if not row then print("[Reforged] wave-class rejected: unknown AI proto " .. tostring(name)); return end
  ExecuteInGameThread(function()
    local c = coordinator()
    if not c then print("[Reforged] wave-class aborted: no coordinator"); return end
    if not RoundActive(c) then print("[Reforged] wave-class rejected: native SetAllAICharactersClass walks the same queue as the crashing wave-amount call"); return end
    local ok, err = pcall(function() c:SetAllAICharactersClass(FName(row.name, EFindName.FNAME_Add)) end)
    print(string.format("[Reforged] wave-class pending-commands=%s call=%s", row.name,
      ok and "ok" or tostring(err)))
  end)
end

local function ParseCount(value, command)
  local count = tonumber(value)
  if not count or count < 1 or count > 100 or count % 1 ~= 0 then
    print("[Reforged] command rejected: " .. command .. " count must be an integer from 1 to 100")
    return nil
  end
  return count
end

local function InspectProtoPointers()
  local lib
  pcall(function() lib = FindFirstOf("OMDProtoBlueprintLibrary") end)
  if not lib then pcall(function() lib = FindFirstOf("Default__OMDProtoBlueprintLibrary") end) end
  print("[Reforged] proto-inspect library=" .. (lib and tostring(lib:GetFullName()) or "not found"))
  local ok, actors = pcall(FindAllOf, "OMDAICharacter")
  if not ok or not actors then print("[Reforged] proto-inspect actors unavailable"); return end
  local checked = 0
  for _, actor in ipairs(actors) do
    pcall(function()
      if not actor:IsValid() or checked >= 3 then return end
      local full = actor:GetFullName()
      if full:find("BP_Wisp_") then return end
      checked = checked + 1
      local protoOk, proto = pcall(function() return actor.protodata end)
      if not protoOk or not proto then
        print("[Reforged] proto-inspect actor=" .. full .. " property-error=" .. tostring(proto))
        return
      end
      local fields = string.format("A=%s B=%s C=%s D=%s", tostring(proto.A), tostring(proto.B), tostring(proto.C), tostring(proto.D))
      local hasOk, has = pcall(function() return lib:HasValue_OMDSoftProtoPtr(proto) end)
      local validOk, valid = pcall(function() return lib:IsValid_OMDSoftProtoPtr(proto) end)
      print(string.format("[Reforged] proto-inspect actor=%s struct={%s} HasValue=%s IsValid=%s",
        full, fields, hasOk and tostring(has) or ("ERROR " .. tostring(has)),
        validOk and tostring(valid) or ("ERROR " .. tostring(valid))))
    end)
  end
  if checked == 0 then print("[Reforged] proto-inspect found no non-Wisp AI characters") end
end

local function InspectDoors()
  local ok, spawners = pcall(FindAllOf, "OMDAISpawner")
  if not ok or not spawners then print("[Reforged] door-inspect spawners unavailable"); return end
  print("[Reforged] door-inspect spawner-count=" .. tostring(#spawners))
  for _, spawner in ipairs(spawners) do
    pcall(function()
      if not spawner:IsValid() then return end
      local index = tostring(spawner.indexInLevel)
      local active = tostring(spawner.bIsActive)
      local locOk, location = pcall(function() return spawner:K2_GetActorLocation() end)
      local rotOk, rotation = pcall(function() return spawner:K2_GetActorRotation() end)
      local pointOk, point = pcall(function() return spawner.StartingPathPoint end)
      local pointName = pointOk and tostring(point) or ("ERROR " .. tostring(point))
      if pointOk and point then
        local resolvedOk, resolved = pcall(function() return point:Get() end)
        if resolvedOk and resolved then
          local nameOk, fullName = pcall(function() return resolved:GetFullName() end)
          if nameOk then pointName = fullName end
        end
      end
      local doorOk, door = pcall(function() return spawner.StartingDoor end)
      local doorName = doorOk and tostring(door) or ("ERROR " .. tostring(door))
      local doorLocation, doorRotation, openText = "?", "?", "?"
      if doorOk and door then
        local resolvedOk, resolved = pcall(function() return door:Get() end)
        if resolvedOk and resolved then door = resolved end
        local nameOk, fullName = pcall(function() return door:GetFullName() end)
        if nameOk then doorName = fullName end
        local positionOk, position = pcall(function() return door:K2_GetActorLocation() end)
        local facingOk, facing = pcall(function() return door:K2_GetActorRotation() end)
        if positionOk then doorLocation = tostring(position) end
        if facingOk then doorRotation = tostring(facing) end
        local openOk, openValue = pcall(function() return door.bIsOpen end)
        if openOk and openValue ~= nil then openText = tostring(openValue) end
      end
      local usable, reason = DoorUsable(spawner)
      print(string.format("[Reforged] door-inspect spawner index=%s active=%s actor=%s location=%s rotation=%s startPoint=%s door=%s doorLocation=%s doorRotation=%s usable=%s reason=%s bIsOpen=%s",
        index, active, spawner:GetFullName(), locOk and tostring(location) or ("ERROR " .. tostring(location)),
        rotOk and tostring(rotation) or ("ERROR " .. tostring(rotation)), pointName, doorName, doorLocation, doorRotation,
        tostring(usable), tostring(reason), openText))
    end)
  end
  local pointOk, points = pcall(FindAllOf, "OMDPathPoint")
  if not pointOk or not points then print("[Reforged] door-inspect path points unavailable"); return end
  print("[Reforged] door-inspect path-point-count=" .. tostring(#points))
  for _, point in ipairs(points) do
    pcall(function()
      if not point:IsValid() then return end
      print(string.format("[Reforged] door-inspect point index=%s actor=%s location=%s rotation=%s parent=%s",
        tostring(point.PointIndex), point:GetFullName(), tostring(point:K2_GetActorLocation()),
        tostring(point:K2_GetActorRotation()), tostring(point.ParentPath)))
    end)
  end
end

-- Direct spawn path. SpawnEntityForEntity(ControllingCharacter, position,
-- rotation, proto, count, bResurrected, out) is the native helper behind the
-- coordinator. The helper reads ControllingCharacter+0x258 without a nil
-- check, so the controlling character must be a live AI character.
local function ProtoLibrary()
  local lib
  pcall(function() lib = FindFirstOf("OMDProtoBlueprintLibrary") end)
  if not lib then pcall(function() lib = FindFirstOf("Default__OMDProtoBlueprintLibrary") end) end
  return lib
end

local function ProtoCheck(name)
  local row = PROTO_BY_NAME[name]
  if not row then print("[Reforged] proto-check rejected: unknown AI proto " .. tostring(name)); return end
  ExecuteInGameThread(function()
    local lib = ProtoLibrary()
    if not lib then print("[Reforged] proto-check " .. row.name .. ": library not found"); return end
    local okF, ptr, found = pcall(function()
      return lib:FindAICharacterSoftProtoPtrByName(FName(row.name, EFindName.FNAME_Add))
    end)
    print(string.format("[Reforged] proto-check %s find ok=%s ptr=%s found=%s",
      row.name, tostring(okF), tostring(ptr), tostring(found)))
    if not okF or not ptr then return end
    local okG, data, success = pcall(function() return lib:GetAICharacterProtodata(ptr) end)
    print(string.format("[Reforged] proto-check %s data ok=%s data=%s success=%s",
      row.name, tostring(okG), tostring(data), tostring(success)))
  end)
end

local function FindSpawnerByIndex(index)
  local ok, spawners = pcall(FindAllOf, "OMDAISpawner")
  if not ok or not spawners then return nil end
  for _, spawner in ipairs(spawners) do
    local okI, idx = pcall(function() return spawner.indexInLevel end)
    if okI and tostring(idx) == tostring(index) then return spawner end
  end
  return nil
end

-- Restore stock spawner values after each door call. The post-restore crash of 2026-10-12 was a null DeathType (f3c6e57), not the restore writes.
if RESTORE_DOOR_STOCK == nil then RESTORE_DOOR_STOCK = true end
-- Stock snapshot per spawner key, and the count of door calls still running on each spawner.
DOOR_STOCK = DOOR_STOCK or {}
DOOR_PENDING = DOOR_PENDING or {}
-- Map epoch: ReforgedMapLeave adds 1 before the old map's objects are freed. A call that started in an older epoch
-- treats its actors as gone and does not touch them.
MAP_EPOCH = MAP_EPOCH or 0
-- Keeps the first snapshot for a key. A later call must not record the test values of an earlier call as stock.
function DoorStockTake(key, snapshot)
  if DOOR_STOCK[key] == nil then DOOR_STOCK[key] = snapshot end
  return DOOR_STOCK[key]
end
-- Counts one more door call on this spawner. Returns the new count.
function DoorCallBegin(key)
  DOOR_PENDING[key] = (DOOR_PENDING[key] or 0) + 1
  return DOOR_PENDING[key]
end
-- Counts one door call off this spawner. Returns true when no call is pending.
function DoorCallEnd(key)
  DOOR_PENDING[key] = math.max((DOOR_PENDING[key] or 0) - 1, 0)
  return DOOR_PENDING[key] == 0
end
-- True when any spawner has a door call pending. False for an empty table or all zeros.
function DoorCallsPending()
  for _, count in pairs(DOOR_PENDING) do
    if count > 0 then return true end
  end
  return false
end
-- Manual override list: door index -> true keeps that door out of wave calls. Empty by default.
-- The default check is DoorUsable (placement rule).
WAVE_EXCLUDED_DOORS = {}
-- true: a wave call needs an open door. Set by `placement-open on|off`.
if PLACEMENT_REQUIRE_OPEN == nil then PLACEMENT_REQUIRE_OPEN = true end

-- Static spawners that never take a wave call. Level name -> spawner actor name -> reason.
-- Source: the Endless door map (forcefield spawners). The Scenario_17 entry is the
-- door that spawned behind a closed door before a game exit on 2026-10-12.
-- Scenario_Ice_03 (Frostbitten): Door5 and Door6 have no OnDoorOpened binding in the map export. A pawn from MobSpawnerDoor1
-- did not leave the door in 2 of 2 calls (live run 2026-10-17).
-- MobSpawnerDoor2 is inferred from the same missing binding.
PLACEMENT_STATIC = {
  ScenarioDLC_01 = { MobSpawnerDoor2 = "flyer-door", MobSpawnerDoor3 = "flyer-door" },
  ScenarioDLC_02 = { MobSpawnerDoor3 = "flyer-door" },
  ScenarioDLC_05 = { MobSpawnerDoor2 = "flyer-door" },
  Scenario_Ice_01 = { MobSpawnerDoor2 = "flyer-door" },
  Scenario_Ice_02 = { MobSpawnerDoor3 = "flyer-door" },
  Scenario_Ice_03 = { MobSpawnerDoor1 = "door-not-opened", MobSpawnerDoor2 = "door-not-opened" },
  Scenario_Sand_05 = { MobSpawnerDoor3 = "flyer-door" },
  Scenario_17 = { BP_OMDAISpawner_2 = "crash-2026-10-12" },
  -- Scenario_18 (Order Temple, #101): the coordinator opens these Vorwick rift spawners itself (OpenRedRift actions). They have no door.
  Scenario_18 = {
    ["OMDAISpawner4-RedRift1"] = "rift-spawner",
    ["OMDAISpawner5-RedRift2"] = "rift-spawner",
    ["OMDAISpawner6-RedRift3"] = "rift-spawner",
    ["OMDAISpawner7-RedRift4"] = "rift-spawner",
    ["OMDAISpawner8-RedRift5"] = "rift-spawner",
    ["OMDAISpawner9-RedRift6"] = "rift-spawner",
    ["OMDAISpawner10-RedRift7"] = "rift-spawner",
    ["OMDAISpawner11-RedRift8"] = "rift-spawner",
    ["OMDAISpawner12-RedRift9"] = "rift-spawner",
    ["OMDAISpawner13-RedRift10"] = "rift-spawner",
    ["OMDAISpawner14-RedRift11"] = "rift-spawner",
  },
}

-- Levels whose BP_Door_Forcefield doors are ground doors (War Scenario maps, #101). DoorUsable does not give "flyer-door" there.
PLACEMENT_GROUND_FORCEFIELD = { Scenario_06 = true, Scenario_09 = true, Scenario_12 = true, Scenario_15 = true, Scenario_18 = true, ScenarioDLC_03 = true, Scenario_Sand_03 = true }

-- SpawnerLevelAndName(spawner) -> level, actor name, or nil, nil when the full name does not match.
-- Full name example: "BP_OMDAISpawner_C /Game/Maps/CampaignDLC/ScenarioDLC_01/ScenarioDLC_01.ScenarioDLC_01:PersistentLevel.MobSpawnerDoor3"
local function SpawnerLevelAndName(spawner)
  local okN, fullName = pcall(function() return spawner:GetFullName() end)
  if not okN or not fullName then return nil, nil end
  local text = tostring(fullName)
  local level = text:match("%.([^%.]+):PersistentLevel%.")
  local name = text:match(":PersistentLevel%.(.+)$")
  if not level or not name then return nil, nil end
  return level, name
end

-- DoorUsable(spawner) -> usable, reason. Checks run in order; the first failure gives the reason.
-- Each field read and call is wrapped in pcall. Flyer doors (BP_Door_Forcefield) never take a wave call.
-- When a field read raises an error (seen in UE4SS on 2026-10-17), the spawner is marked static-only
-- and gives "ok-static". The static list above still applies to it.
function DoorUsable(spawner)
  local okV, valid = pcall(function() return spawner:IsValid() end)
  if not okV or not valid then return false, "invalid" end
  local okI, index = pcall(function() return tonumber(spawner.indexInLevel) end)
  if okI and index and WAVE_EXCLUDED_DOORS[index] then return false, "excluded" end
  local level, name = SpawnerLevelAndName(spawner)
  if level and PLACEMENT_STATIC[level] and PLACEMENT_STATIC[level][name] then
    return false, PLACEMENT_STATIC[level][name]
  end
  local staticOnly = false
  local okP, pointRef = pcall(function() return spawner.StartingPathPoint end)
  local okPG, point = false, nil
  if okP then okPG, point = pcall(function() return pointRef:Get() end) end
  if not okP or not okPG then
    staticOnly = true
  elseif not point then
    return false, "no-path"
  end
  local okD, doorRef = pcall(function() return spawner.StartingDoor end)
  local okG, door = false, nil
  if okD then okG, door = pcall(function() return doorRef:Get() end) end
  if not okD or not okG then
    staticOnly = true
  else
    if not door then return false, "no-door" end
    local okN, doorName = pcall(function() return door:GetFullName() end)
    if okN and tostring(doorName):find("BP_Door_Forcefield", 1, true) and not (level and PLACEMENT_GROUND_FORCEFIELD[level]) then
      return false, "flyer-door"
    end
    if PLACEMENT_REQUIRE_OPEN then
      local okO, open = pcall(function() return door.bIsOpen end)
      if not okO or open == nil then return false, "open-unknown" end
      if open == false then return false, "closed" end
    end
  end
  if staticOnly then return true, "ok-static" end
  return true, "ok"
end

local function JoinOrNone(list)
  if #list == 0 then return "none" end
  return table.concat(list, ",")
end

local function GetSpawnerIndexes()
  local indexes, excluded = {}, {}
  local ok, spawners = pcall(FindAllOf, "OMDAISpawner")
  if not ok or not spawners then spawners = {} end
  for _, spawner in ipairs(spawners) do
    pcall(function()
      local okI, raw = pcall(function() return tonumber(spawner.indexInLevel) end)
      local index = okI and raw or nil
      local usable, reason = DoorUsable(spawner)
      if usable and index and index % 1 == 0 then
        indexes[#indexes + 1] = index
      else
        if usable then reason = "bad-index" end
        excluded[#excluded + 1] = { sort = index or math.huge, label = tostring(index or "?") .. ":" .. reason }
      end
    end)
  end
  table.sort(indexes)
  table.sort(excluded, function(a, b) return a.sort < b.sort end)
  local labels = {}
  for _, e in ipairs(excluded) do labels[#labels + 1] = e.label end
  print(string.format("[Reforged] placement doors=%s excluded=%s requireOpen=%s",
    JoinOrNone(indexes), JoinOrNone(labels), tostring(PLACEMENT_REQUIRE_OPEN == true)))
  return indexes
end
PlacementDoors = GetSpawnerIndexes -- test alias

-- Doorway transform: the spawner's StartingDoor when it resolves, else the spawner itself.
local function DoorTransform(index)
  local spawner = FindSpawnerByIndex(index)
  if not spawner then return nil, "no spawner with indexInLevel " .. tostring(index) end
  local loc, rot, source
  local okD, door = pcall(function() return spawner.StartingDoor end)
  if okD and door then
    local okR, resolved = pcall(function() return door:Get() end)
    if okR and resolved then
      local okL, l = pcall(function() return resolved:K2_GetActorLocation() end)
      local okT, t = pcall(function() return resolved:K2_GetActorRotation() end)
      if okL and l then loc, source = l, "door" end
      if okT and t then rot = t end
    end
  end
  if not loc then
    local okL, l = pcall(function() return spawner:K2_GetActorLocation() end)
    local okT, t = pcall(function() return spawner:K2_GetActorRotation() end)
    if okL and l then loc, source = l, "spawner" end
    if okT and t then rot = t end
  end
  if not loc then return nil, "no location for spawner " .. tostring(index) end
  return { loc = loc, rot = rot or { Pitch = 0, Yaw = 0, Roll = 0 }, source = source }
end

local function LiveNonWispAI()
  local found = {}
  local ok, list = pcall(FindAllOf, "OMDAICharacter")
  if not ok or not list then return found end
  for _, actor in ipairs(list) do
    pcall(function()
      if not actor:IsValid() then return end
      local full = actor:GetFullName()
      if full:find("BP_Wisp_") then return end
      found[#found + 1] = { actor = actor, full = full }
    end)
  end
  return found
end

local function DistanceTo(actor, point)
  local ok, p = pcall(function() return actor:K2_GetActorLocation() end)
  if not ok or not p then return math.huge end
  local dx, dy, dz = p.X - point.X, p.Y - point.Y, p.Z - point.Z
  return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- Vector text for logs. UE4SS returns FVector as a table with X, Y, Z.
local function Vec(v)
  local ok, text = pcall(function()
    return string.format("(%.0f,%.0f,%.0f)", v.X, v.Y, v.Z)
  end)
  return ok and text or tostring(v)
end

local function ShortName(full)
  return full:match("(BP_[%w_]+)_C_%d+") or full
end

-- BEGIN WATCH STREAM. Reads only: no asset loads, no spawn calls. Every game read is in pcall.
-- Output: watch.jsonl beside director.cmd, one JSON object per line. Section: "Game watch stream".
if WATCH_ON == nil then WATCH_ON = true end
if WATCH_TRACK_MS == nil then WATCH_TRACK_MS = 2000 end
if WATCH_HITS == nil then WATCH_HITS = false end -- `watch-hits on`. Off by default; the hooks register on the first `on`.
do
  local NULL = setmetatable({}, { __name = "null" }) -- field value that encodes as null
  local ARRAY = {} -- metatable marker: an empty list encodes as []
  local W = { seq = 0, pass = 0, pawns = {}, doors = {}, markerOk = false, missing = {} }

  local function NV(v) if v == nil then return NULL end return v end
  local function List(t) return setmetatable(t, ARRAY) end
  WatchList = List -- export: JSON array marker for the Play screen events
  WatchNull = NULL -- export: JSON null. A nil inside an array breaks the array, so the Play screen list needs it

  local function JsonString(s)
    local out = s:gsub('[%c"\\]', function(c)
      if c == '"' then return '\\"' end
      if c == "\\" then return "\\\\" end
      if c == "\n" then return "\\n" end
      if c == "\r" then return "\\r" end
      if c == "\t" then return "\\t" end
      return string.format("\\u%04x", c:byte())
    end)
    return '"' .. out .. '"'
  end

  -- Text for a key or a value that is not a string or a number. Under UE4SS tostring can fail or return a
  -- non-string ("attempt to compare table with string" in the key sort). Such a value gets "<type>".
  local function SafeText(k)
    local t = type(k)
    if t == "string" then return k end
    if t == "number" then return tostring(k) end
    local ok, s = pcall(tostring, k)
    if ok and type(s) == "string" then return s end
    return "<" .. t .. ">"
  end

  local Encode
  function Encode(v)
    local t = type(v)
    if v == nil or v == NULL then return "null" end
    if t == "boolean" then return tostring(v) end
    if t == "number" then
      if v ~= v or v == math.huge or v == -math.huge then return "null" end
      local iv = math.tointeger(v)
      if iv then return string.format("%d", iv) end
      -- Six decimals, trailing zeros removed. One decimal wrote 0.08 as 0.1 (EndlessDamageAdditionPerWave).
      local s = string.format("%.6f", v):gsub("0+$", ""):gsub("%.$", "")
      return s
    end
    if t == "string" then return JsonString(v) end
    if t ~= "table" then return JsonString(SafeText(v)) end
    local n, count = #v, 0
    for _ in pairs(v) do count = count + 1 end
    local isArray = n > 0 and count == n
    if isArray then
      for i = 1, n do if v[i] == nil then isArray = false; break end end
    end
    local parts = {}
    if isArray then
      for i = 1, n do parts[i] = Encode(v[i]) end
      return "[" .. table.concat(parts, ",") .. "]"
    end
    if n == 0 and getmetatable(v) == ARRAY then return "[]" end
    -- Key text is built once per key. The sort compares text only.
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = { text = SafeText(k), key = k } end
    table.sort(keys, function(a, b) return a.text < b.text end)
    for _, item in ipairs(keys) do parts[#parts + 1] = JsonString(item.text) .. ":" .. Encode(v[item.key]) end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  WatchJson = Encode

  local function Path()
    return WAVE_COMMAND_PATH and (WAVE_COMMAND_PATH:gsub("director%.cmd$", "watch.jsonl")) or nil
  end
  WatchFilePath = Path
  -- Tests call this before they delete the temp folder. The game does not call it.
  function WatchClose() if W.fh then pcall(function() W.fh:close() end) end W.fh, W.path = nil, nil end

  -- ev is the event name, when the caller has one. The line names it first.
  local function WatchErr(text, ev)
    local now = os.time()
    if W.errAt and now - W.errAt < 30 then return end
    W.errAt = now
    local msg = SafeText(text)
    if ev ~= nil then
      print("[Reforged] watch error ev=" .. SafeText(ev) .. " " .. msg)
    else
      print("[Reforged] watch error " .. msg)
    end
  end

  -- Keeps the previous match (S3, #103). An existing watch.jsonl becomes watch.prev.jsonl before this game's first open.
  -- Every read and write is in pcall. A failed rename leaves the old file where it is.
  local function KeepPrevious(path)
    local prev = (path:gsub("watch%.jsonl$", "watch.prev.jsonl"))
    pcall(function()
      local old = io.open(path, "r")
      if not old then return end
      old:close()
      os.remove(prev)
      os.rename(path, prev)
    end)
  end

  -- Opens watch.jsonl with mode "w" at the first event. A new path (a new game start) gives a new file and restarts n.
  local function OpenFile()
    local path = Path()
    if not path then return nil end
    if W.fh and W.path == path then return W.fh end
    if W.fh then pcall(function() W.fh:close() end); W.fh = nil end
    if not W.keptPrev then W.keptPrev = true; KeepPrevious(path) end
    local fh, err = io.open(path, "w")
    if not fh then
      if not W.openWarned then
        W.openWarned = true
        print("[Reforged] watch file not opened: " .. tostring(err))
      end
      return nil
    end
    W.fh, W.path, W.seq = fh, path, 0
    return fh
  end

  local function Write(ev, fields)
    local fh = OpenFile()
    if not fh then return end
    local tbl = {}
    if fields then for k, v in pairs(fields) do tbl[k] = v end end
    tbl.ev, tbl.t, tbl.n = ev, os.time(), W.seq + 1
    local line = Encode(tbl) -- before the seq step: a failed encode leaves no gap in n
    W.seq = W.seq + 1
    fh:write(line, "\n")
    fh:flush()
  end

  function WatchEmit(ev, fields)
    if not WATCH_ON then return end
    local ok, err = pcall(Write, ev, fields)
    if not ok then WatchErr(err, ev) end
  end

  local function Pos(actor)
    local x, y, z
    pcall(function()
      local p = actor:K2_GetActorLocation()
      x, y, z = p.X, p.Y, p.Z
    end)
    return x, y, z
  end

  -- True when a location is unreadable or within 1 unit of the origin. The engine gives (0,0,0) for an
  -- unset spawner and for a pawn that is being removed. Such a read is not a position.
  local function IsOrigin(x, y, z)
    if x == nil or y == nil or z == nil then return true end
    return math.abs(x) <= 1 and math.abs(y) <= 1 and math.abs(z) <= 1
  end

  local function NearestDoor(x, y, z)
    if IsOrigin(x, y, z) then return nil, nil end
    local best, bestD = nil, nil
    for _, d in ipairs(W.doors) do
      if not IsOrigin(d.x, d.y, d.z) then
        local dx, dy, dz = d.x - x, d.y - y, d.z - z
        local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
        if not bestD or dist < bestD then best, bestD = d.i, dist end
      end
    end
    return best, bestD
  end

  -- Raw 64-bit text for the counted marker. Lua may give a number or a boxed value; both are kept as text.
  local function RawText(v)
    if v == nil then return nil end
    local iv = type(v) == "number" and math.tointeger(v)
    if iv then return string.format("0x%x", iv) end
    return tostring(v)
  end

  -- counted: true when the pawn marker equals the coordinator address, false when it differs, nil when unreadable.
  local function Counted(actor, coordAddr)
    if not W.markerOk then return nil, nil end
    local okV, v = pcall(function() return actor.ReforgedSpawnCoord end)
    if not okV then v = nil end
    local raw = RawText(v)
    if v == nil or coordAddr == nil then return nil, raw end
    local same
    if type(v) == "number" and type(coordAddr) == "number" then same = v == coordAddr
    else same = tostring(v) == tostring(coordAddr) end
    return same, raw
  end

  local function CoordAddress()
    local addr = nil
    pcall(function() addr = coordinator():GetAddress() end)
    return addr
  end

  -- Counted rule for one pawn, the same rule as the counted field of spawn events.
  -- Returns true, false or nil (unreadable). Uses the marker registered above; does not register it again.
  function IsCountedPawn(actor)
    local same = Counted(actor, CoordAddress())
    return same
  end

  local function Start()
    if W.started then return end
    W.started = true
    local okM, mode = pcall(function() return ReadEndlessMode() end)
    WatchEmit("start", { testing = NV(TESTING), mode = NV(okM and mode or nil) })
  end

  local function Round(v)
    if v == nil then return NULL end
    return math.floor(v + 0.5)
  end

  -- bIsDead is a reflected bitfield. Only a Lua true counts as dead. A failed read counts as alive.
  local function IsDead(actor)
    local ok, v = pcall(function() return actor.bIsDead end)
    return ok and v == true
  end
  -- Shared with the anchor commands: the dead rule and the null value for event fields.
  PawnIsDead = IsDead
  WatchNull = NULL

  local function Health(actor)
    local ok, h = pcall(function() return actor:GetHealth() end)
    if ok then return h end
    return nil
  end

  -- died cause (#103): `rift` when the pawn's last good position is within 400 units of a live OMDRift, else `kill`.
  -- An unknown position gives `kill`. RiftList reads the rifts now, so a moved rift is measured where it stands.
  local function DeathCause(x, y, z)
    if IsOrigin(x, y, z) then return "kill" end
    local okR, rifts = pcall(RiftList)
    if not okR or type(rifts) ~= "table" then return "kill" end
    for _, r in ipairs(rifts) do
      local l = r.loc
      if l then
        local dx, dy, dz = l.X - x, l.Y - y, l.Z - z
        if math.sqrt(dx * dx + dy * dy + dz * dz) <= 400 then return "rift" end
      end
    end
    return "kill"
  end

  -- Track row hp and tg (#103). hp is GetHealth to 0.1. tg is the kind of Controller:GetEnemyActor():
  -- 0 none, 1 the player pawn, 2 barricade or trap, 3 door, 4 other. nil when a read fails. Each read is in pcall.
  -- The controller is the Controller property, else GetController() (the property read was not valid on a live
  -- OrcLight, docs/game-thread-assert-research-2026-10-18.md). The first read error is printed once (W.tgErrLogged).
  local function TrackReads(actor, playerAddr)
    local hp, tg = nil, nil
    local okH, h = pcall(function() return actor:GetHealth() end)
    if okH and type(h) == "number" then hp = math.floor(h * 10 + 0.5) / 10 end
    local okT, kind = pcall(function()
      local ctrl = nil
      local okP, cP = pcall(function() return actor.Controller end)
      if okP and cP ~= nil then ctrl = cP end
      if ctrl == nil then
        local okG, cG = pcall(function() return actor:GetController() end)
        if okG and cG ~= nil then ctrl = cG end
      end
      if ctrl == nil then error("no controller", 0) end
      local target = ctrl:GetEnemyActor()
      -- No target: nil, or a UE4SS wrapper that is not valid (live 2026-10-21). Both are 0.
      if target == nil then return 0 end
      local okV, valid = pcall(function() return target:IsValid() end)
      if okV and valid ~= true then return 0 end
      local addr = target:GetAddress()
      if playerAddr ~= nil and addr == playerAddr then return 1 end
      local full = target:GetFullName()
      if type(full) ~= "string" then return 4 end
      if full:find("Barricade") or full:find("Trap") then return 2 end
      if full:find("Door") then return 3 end
      return 4
    end)
    if okT then tg = kind
    elseif not W.tgErrLogged then
      W.tgErrLogged = true
      print("[Reforged] watch tg read err=" .. tostring(kind))
    end
    return hp, tg
  end

  -- spawn inv (#103): the spawner's bInvulnerableOnSpawn. Read once per door, at its first spawn. nil when unreadable.
  local function DoorInv(i)
    if i == nil then return nil end
    for _, d in ipairs(W.doors) do
      if d.i == i then
        if not d.invRead then
          d.invRead = true
          local okI, v = pcall(function() return d.actor.bInvulnerableOnSpawn end)
          if okI and type(v) == "boolean" then d.inv = v end
        end
        return d.inv
      end
    end
    return nil
  end

  -- Level name from a full object name: the text after /Game/ up to the first ., then its last path part.
  -- Example: .../Maps/CampaignDLC_Ice/Scenario_Ice_03/Scenario_Ice_03.Scenario_Ice_03:... -> Scenario_Ice_03
  local function LevelFromFullName(full)
    local path = full and full:match("/Game/([^%.]+)")
    return path and path:match("([^/]+)$") or nil
  end

  -- Door list in the map.doors format. Used by the map event and the doors event.
  local function DoorList()
    local shown = List({})
    for _, d in ipairs(W.doors) do
      shown[#shown + 1] = { i = NV(d.i), x = NV(d.x), y = NV(d.y), z = NV(d.z) }
    end
    return shown
  end

  -- Runs on each tick until every door has a real location. Re-reads only doors still at the origin.
  -- Emits one doors event per map event.
  local function DoorsTick()
    if W.doorsSent or #W.doors == 0 then return end
    local allReal = true
    for _, d in ipairs(W.doors) do
      if IsOrigin(d.x, d.y, d.z) and d.actor then
        local x, y, z = Pos(d.actor)
        if not IsOrigin(x, y, z) then d.x, d.y, d.z = x, y, z end
      end
      if IsOrigin(d.x, d.y, d.z) then allReal = false end
    end
    if allReal then
      W.doorsSent = true
      WatchEmit("doors", { doors = DoorList() })
    end
  end

  -- Game events. W.phase, W.hoardKey, W.playableSent and W.paused hold the last known value. nil or false means not known yet.
  -- A failed read leaves the last known value and emits nothing. WatchMapReady resets all four.
  -- Break kind: W.brk is the last kind. W.seenCombat is true once the phase was combat on this map.
  -- BreakRead: one read of the break state. to is "build" or "combat", or nil when bIsGoBreakActive fails.
  -- kind is "timed", "build" (a go break before any combat), "go", or nil (combat, or a failed timed read).
  -- timer is OnslaughtTimer rounded to 0.1 s, or nil when the read fails.
  local function BreakRead()
    local out = { to = nil, kind = nil, timer = nil }
    local okG, gs = pcall(FindFirstOf, "OMDGameState")
    if not okG or not gs then return out end
    local okV, goBreak = pcall(function()
      if not gs:IsValid() then return nil end
      return gs.bIsGoBreakActive
    end)
    if not okV or type(goBreak) ~= "boolean" then return out end
    local okT, timed = pcall(function() return gs.bIsTimedBreakActive end)
    local okR, raw = pcall(function() return gs.OnslaughtTimer end)
    if okR and type(raw) == "number" then out.timer = math.floor(raw * 10 + 0.5) / 10 end
    if not okT or type(timed) ~= "boolean" then
      out.to = goBreak and "build" or "combat"
    elseif timed then
      out.to, out.kind = "build", "timed"
    elseif goBreak then
      out.to = "build"
      out.kind = W.seenCombat and "go" or "build"
    else
      out.to = "combat"
    end
    return out
  end

  local function PhaseTick(wave, iter)
    local b = BreakRead()
    if b.to == nil then return b end
    PHASE_NOW = b.to -- The plan hook reads the phase. W is local to this block.
    if b.to == "combat" then W.seenCombat = true end
    -- A change into a break (build or go) is the start of the break. Classic rolls the coming round here.
    if b.to ~= "combat" and (W.phase == "combat" or W.phase == nil) then pcall(ClassicModBreakStart) end
    -- A change into combat is a Classic round start. It does nothing unless the Classic modifier setting is on.
    -- A change into combat ends the break popup (hold entries of the modifier tag). Runs before the fallbacks.
    if b.to == "combat" and W.phase ~= "combat" then pcall(BannerHoldEnd, "modifier", "combat") end
    if b.to == "combat" and W.phase ~= "combat" then pcall(ClassicModCombatStart) end
    -- The Reforged modifier banner of this round. Nothing is pending unless the plan hook rolled an id.
    if b.to == "combat" and W.phase ~= "combat" then pcall(ModBannerCombatStart) end
    -- The War Scenario map boss of the Reforged round (#101 M5). Reforged only.
    if b.to == "combat" and W.phase ~= "combat" and QueueBlockMode() == "reforged" then pcall(ReforgedMapBossCombatStart) end
    if b.to ~= W.phase or b.kind ~= W.brk then
      WatchEmit("phase", {
        from = NV(W.phase), to = b.to, wave = NV(wave), iter = NV(iter),
        brk = NV(b.kind), timer = NV(b.timer),
      })
      W.phase = b.to
    end
    W.brk = b.kind
    return b
  end

  -- HoardReleased returns "no-game-state" when the game state or its read fails. That is a failed read: no event.
  local function HoardTick()
    local okH, released, reason = pcall(HoardReleased)
    if not okH or reason == nil or reason == "no-game-state" then return end
    local key = tostring(released) .. "|" .. tostring(reason)
    if key ~= W.hoardKey then
      WatchEmit("hoard", { released = released == true, reason = tostring(reason) })
      W.hoardKey = key
    end
  end

  local function PlayableTick()
    if W.playableSent then return end
    local okP, playable, waveText, iterText = pcall(LevelPlayable)
    if not okP or playable ~= true then return end
    W.playableSent = true
    local diff = ReadGameDifficulty()
    -- The match starts with diff. A wrong value is set again here, and diff2 is the read-back after that set.
    local diff2 = nil
    if diff ~= ENDLESS_DIFFICULTY then
      -- #100 items 5.2: a custom map in Classic keeps the borrowed difficulty. The native end-game needs a mode byte other than 3.
      local okK, keep = pcall(function()
        local lib = REFORGED_CUSTOM and REFORGED_CUSTOM.lib
        if not lib or type(lib.KeepsBorrowedDifficulty) ~= "function" then return false end
        local ws = FindFirstOf("WorldSettings")
        if not ws or not ws:IsValid() then return false end
        return lib.KeepsBorrowedDifficulty(ws:GetFullName(), ENDLESS_MODE) == true
      end)
      if okK and keep == true then
        print("[Reforged] difficulty at playable=" .. tostring(diff) .. " kept (custom map, classic)")
      else
        pcall(SetEndlessDifficulty, "playable-fix")
        diff2 = ReadGameDifficulty()
      end
    end
    local dmRead = DmEndlessRead() or {}
    -- The level-load popup names the mode. It runs before the playable event, which carries its title.
    local modeTitle = ModeBannerShow()
    WatchEmit("playable", { wave = NV(tonumber(waveText)), iter = NV(tonumber(iterText)), difficulty = NV(diff),
      difficultyFixed = diff2 or WatchNull,
      dmHealth = NV(dmRead.health), dmSpeed = NV(dmRead.speed), dmDamage = NV(dmRead.damage), testMode = TEST_MODE == true,
      modeBanner = modeTitle })
    print("[Reforged] difficulty at playable=" .. tostring(diff) .. " fixed=" .. tostring(diff2 or "none"))
  end

  -- Pause state from UGameplayStatics:IsGamePaused. The class default object is found once and cached.
  -- No event on the first known value; an event on each later change.
  local function PauseTick(c)
    if not c then return end
    if not W.statics then
      local okF, o = pcall(StaticFindObject, "/Script/Engine.Default__GameplayStatics")
      if okF and o then W.statics = o end
    end
    if not W.statics then return end
    local okP, paused = pcall(function() return W.statics:IsGamePaused(c) end)
    if not okP or type(paused) ~= "boolean" then return end
    if W.paused ~= nil and paused ~= W.paused then
      WatchEmit("pause", { paused = paused })
    end
    W.paused = paused
  end

  -- BEGIN WATCH HITS. `hit` events: damage to the player, from BP_AnyDamageTaken (h1) and ReceiveAnyDamage (h2).
  -- Off by default (WATCH_HITS). The hooks register on the first `watch-hits on`.
  -- Hook rule (crash 2026-10-18): a hook parameter is valid only during the call. HitsBody copies numbers and strings only.
  -- HitsSchedule is the only deferred step; it receives copies, never a parameter.
  -- seen: hook calls with dmg > 0. matched: those whose victim is the player pawn. Both count from load on.
  local HITS = { reg = {}, registered = false, rate = { sec = nil, n = 0 }, drop = 0, victimAddr = nil, victimSec = nil,
    dmMod = nil, dmAdd = nil, seen = 0, matched = 0 }
  local HIT_RATE = 20 -- hit events per second; the rest add to `drop`
  local HIT_HOOKS = {
    { src = "h1", path = "/Script/OMD.OMDCharacter:BP_AnyDamageTaken", dmgIdx = 1, typeIdx = 2, causerIdx = 3, pre = 0 },
    { src = "h2", path = "/Script/Engine.Actor:ReceiveAnyDamage", dmgIdx = 1, typeIdx = 2, causerIdx = 4, pre = 1 },
  }

  local function Num(v) if type(v) == "number" then return v end return nil end

  -- The last dot part of a full name (the spawn id rule in Pass), or the last word when there is no dot.
  local function ObjTail(full)
    if not full then return nil end
    return full:match("%.([^%.%s]+)$") or full:match("(%S+)$")
  end

  local function PlayerPawn()
    local pawn = nil
    pcall(function()
      local pc = FindFirstOf("OMDPlayerController")
      if pc and pc:IsValid() then pawn = pc.Pawn end
      if pawn and not pawn:IsValid() then pawn = nil end
    end)
    return pawn
  end

  -- Caches the player's address; the hook compares the victim with it. Reads at most once per second,
  -- so a respawned pawn is matched within 1 s. force skips the limit (used on `watch-hits on`).
  local function HitsPlayerTick(force)
    local sec = os.time()
    if not force and HITS.victimSec == sec then return end
    HITS.victimSec = sec
    local addr = nil
    local pawn = PlayerPawn()
    if pawn then pcall(function() addr = pawn:GetAddress() end) end
    HITS.victimAddr = addr
  end

  -- Endless damage inputs from the difficulty manager. Read on watch-hits on, on each wave change and after dm-set.
  local function HitsDmRead()
    local mod, add = nil, nil
    pcall(function()
      local dm = FindFirstOf("OMDDifficultyManager")
      if dm and dm:IsValid() then
        mod = Num(dm.EndlessDamageModifier)
        add = Num(dm.EndlessDamageAdditionPerWave)
      end
    end)
    HITS.dmMod, HITS.dmAdd = mod, add
  end
  function WatchDmRefresh() if WATCH_HITS then HitsDmRead() end end

  -- Sets hpBefore, hpAfter, delta and clamped, then writes the hit. Plain values only.
  local function HitsFinish(fields, hpBefore, hpAfter)
    local delta, clamped = nil, nil
    if hpBefore and hpAfter then delta = hpBefore - hpAfter; clamped = hpAfter == 0 and 1 or 0 end
    fields.hpBefore, fields.hpAfter = NV(hpBefore), NV(hpAfter)
    fields.delta, fields.clamped = NV(delta), NV(clamped)
    WatchEmit("hit", fields)
  end

  -- h2 runs before the health write, so hpAfter is read on a later step (100 ms). Only copied values are captured.
  local function HitsSchedule(fields, victim, hpBefore)
    WatchHitsDefer(100, function()
      ExecuteInGameThread(function()
        local hpAfter = nil
        local pawn = PlayerPawn()
        if pawn then
          pcall(function() if pawn:GetAddress() == victim then hpAfter = Num(pawn:GetHealth()) end end)
        end
        HitsFinish(fields, hpBefore, hpAfter)
      end)
    end)
  end

  local EnemyHit -- defined after HitsBody (ehit, #103)

  -- The hook body. `self` and the parameters are read here, during the call, and nowhere after it.
  local function HitsBody(h, self, ...)
    if not WATCH_HITS or not WATCH_ON then return end
    local a = { ... }
    local function get(i)
      if a[i] == nil then return nil end
      local ok, v = pcall(function() return a[i]:get() end)
      if ok then return v end
      return nil
    end
    local dmg = Num(get(h.dmgIdx))
    if not dmg or dmg <= 0 then return end -- healing and zero hits are not damage
    HITS.seen = HITS.seen + 1
    -- `self` is a RemoteUnrealParam in a UE4SS hook. Its :get() gives the UObject. A param that fails is skipped.
    local okS, obj = pcall(function() return self:get() end)
    if not okS or obj == nil then return end
    local victim = nil
    pcall(function() victim = obj:GetAddress() end)
    HitsPlayerTick() -- at most one player read per second
    if victim == nil then return end
    if victim ~= HITS.victimAddr then
      EnemyHit(h, obj, get, dmg) -- ehit: a counted pawn victim. Other victims give nothing.
      return
    end -- player victims only below
    HITS.matched = HITS.matched + 1
    local hpNow, hpMax = nil, nil
    pcall(function() hpNow = Num(obj:GetHealth()) end)
    pcall(function() hpMax = Num(obj:GetMaxHealth()) end)
    -- Attacker: the causer. A projectile or other non-pawn causer falls back to its Instigator when that is a counted pawn.
    local causer = get(h.causerIdx)
    local causerFull, aId, aClass, aKind = nil, nil, nil, "other"
    pcall(function() if causer and causer:IsValid() then causerFull = causer:GetFullName() end end)
    if causerFull then aId, aClass = ObjTail(causerFull), causerFull:match("^(%S+)") end
    if aId and W.pawns[aId] then aKind = "pawn" end
    if aKind ~= "pawn" and causer then
      pcall(function()
        local inst = causer.Instigator
        if inst and inst:IsValid() then
          local full = inst:GetFullName()
          local iid = ObjTail(full)
          if iid and W.pawns[iid] then aId, aClass, aKind = iid, full:match("^(%S+)"), "pawn" end
        end
      end)
    end
    local aProto = nil
    if aKind == "pawn" then aProto = W.pawns[aId].proto end
    local dtype = nil
    local dt = get(h.typeIdx)
    pcall(function() if dt and dt:IsValid() then dtype = ObjTail(dt:GetFullName()) end end)
    -- Rate limit: HIT_RATE events per second. Dropped hits are counted in the next event's `drop`.
    local sec = os.time()
    if HITS.rate.sec ~= sec then HITS.rate.sec, HITS.rate.n = sec, 0 end
    if HITS.rate.n >= HIT_RATE then HITS.drop = HITS.drop + 1; return end
    HITS.rate.n = HITS.rate.n + 1
    local fields = {
      src = h.src, pre = h.pre, dmg = dmg, victim = "player", hpMax = NV(hpMax),
      aId = NV(aId), aClass = NV(aClass), aProto = NV(aProto), aKind = aKind, dmgType = NV(dtype),
      wave = NV(W.wave), iter = NV(W.iter), dmMod = NV(HITS.dmMod), dmAdd = NV(HITS.dmAdd),
      drop = HITS.drop,
    }
    HITS.drop = 0
    if h.pre == 0 then
      -- h1 runs after the health write: hpBefore is derived as hpAfter + dmg.
      fields.hpBeforeCalc = 1
      HitsFinish(fields, hpNow and hpNow + dmg or nil, hpNow)
    else
      fields.hpBeforeCalc = 0
      HitsSchedule(fields, victim, hpNow)
    end
  end

  -- ehit (#103): damage to a counted pawn (W.pawns). Same hooks, same rate limit (HITS.rate) as hit.
  -- h1 reads hpAfter after the health write. h2 reads it 100 ms later, from the pawn id (a copy), never from the parameter.
  -- aKind: player (the causer or its Instigator is the player pawn), trap, pawn (a counted pawn), other.
  local function EnemyKind(causer)
    if not causer then return "other" end
    local kind = "other"
    pcall(function()
      if not causer:IsValid() then return end
      local addr = causer:GetAddress()
      if HITS.victimAddr ~= nil and addr == HITS.victimAddr then kind = "player"; return end
      local full = causer:GetFullName()
      local cid = ObjTail(full)
      if cid and W.pawns[cid] then kind = "pawn" end
      if full:find("Trap") then kind = "trap" end
      local inst = causer.Instigator
      if inst and inst:IsValid() then
        if HITS.victimAddr ~= nil and inst:GetAddress() == HITS.victimAddr then kind = "player"; return end
        local iid = ObjTail(inst:GetFullName())
        if kind == "other" and iid and W.pawns[iid] then kind = "pawn" end
      end
    end)
    return kind
  end

  -- nodmg is 1 when hpAfter >= hpBefore (dmg > 0 is already true here). null when a health read failed.
  local function EnemyFinish(fields, hpBefore, hpAfter)
    local nodmg = nil
    if hpBefore and hpAfter then nodmg = hpAfter >= hpBefore and 1 or 0 end
    fields.hpBefore, fields.hpAfter, fields.nodmg = NV(hpBefore), NV(hpAfter), NV(nodmg)
    WatchEmit("ehit", fields)
  end

  function EnemyHit(h, obj, get, dmg)
    local full = nil
    pcall(function() full = obj:GetFullName() end)
    local id = full and ObjTail(full)
    local rec = id and W.pawns[id]
    if not rec then return end
    local sec = os.time()
    if HITS.rate.sec ~= sec then HITS.rate.sec, HITS.rate.n = sec, 0 end
    if HITS.rate.n >= HIT_RATE then HITS.drop = HITS.drop + 1; return end
    HITS.rate.n = HITS.rate.n + 1
    local hpNow = nil
    pcall(function() hpNow = Num(obj:GetHealth()) end)
    local dtype = nil
    local dt = get(h.typeIdx)
    pcall(function() if dt and dt:IsValid() then dtype = ObjTail(dt:GetFullName()) end end)
    local fields = { src = h.src, pre = h.pre, id = id, proto = NV(rec.proto), dmg = dmg,
      aKind = EnemyKind(get(h.causerIdx)), dmgType = NV(dtype) }
    if h.pre == 0 then
      -- h1 runs after the health write: hpBefore is hpAfter + dmg.
      EnemyFinish(fields, hpNow and hpNow + dmg or nil, hpNow)
    else
      -- h2 runs before the write. The copies are the only values the deferred step uses.
      local hpBefore = hpNow
      WatchHitsDefer(100, function()
        ExecuteInGameThread(function()
          local hpAfter = nil
          for _, e in ipairs(LiveNonWispAI()) do
            if ObjTail(e.full) == id then
              pcall(function() hpAfter = Num(e.actor:GetHealth()) end)
              break
            end
          end
          EnemyFinish(fields, hpBefore, hpAfter)
        end)
      end)
    end
  end

  local function HitsHook(h)
    return function(self, ...)
      if not WATCH_HITS then return end
      local ok, err = pcall(HitsBody, h, self, ...)
      if not ok then WatchErr(err, "hit") end
    end
  end

  -- Registers both hooks once. Each registration is pcall-wrapped and printed.
  function WatchHitsRegister()
    if HITS.registered then return end
    HITS.registered = true
    for _, h in ipairs(HIT_HOOKS) do
      local ok, err = SafeRegisterHook(h.path, HitsHook(h))
      HITS.reg[h.src] = ok == true
      print("[Reforged] watch-hits hook " .. h.path .. " registered=" .. tostring(ok) .. (ok and "" or (" err=" .. tostring(err))))
    end
  end

  -- Sets the switch. `off` clears the flag only: the registered hooks return at their first line (UnregisterHook unmeasured).
  function WatchHitsSwitch(on)
    WATCH_HITS = on == true
    if WATCH_HITS then
      WatchHitsRegister()
      HitsPlayerTick(true)
      HitsDmRead()
    end
    return string.format("[Reforged] watch-hits=%s hook=h1 registered=%s hook=h2 registered=%s watch=%s seen=%d matched=%d",
      WATCH_HITS and "on" or "off", tostring(HITS.reg.h1 == true), tostring(HITS.reg.h2 == true), WATCH_ON and "on" or "off",
      HITS.seen, HITS.matched)
  end
  -- Read by hurt-player, which sits below END WATCH STREAM: the player pawn and the hit counters.
  function WatchHurtContext() return PlayerPawn(), HITS.seen, HITS.matched end
  -- Read by RiftMoveKey: true once the phase was combat on this map.
  function WatchSeenCombat() return W.seenCombat == true end
  -- END WATCH HITS

  -- One diff pass. Runs every 500 ms while the watch is on. The tick and track events run on every 2nd pass (1 s).
  local function Pass()
    W.pass = W.pass + 1
    local okDoor, errDoor = pcall(WatchDoorsScan) -- #103 C2: door events, before the rest of the pass
    if not okDoor then WatchErr(WatchErrText(errDoor), "door") end
    if WATCH_HITS then HitsPlayerTick() end
    Start()
    local list = LiveNonWispAI()
    local now = os.time()
    local seen, classes, coordAddr, coordTried, deadNow = {}, {}, nil, false, 0
    for _, e in ipairs(list) do
      -- The object name is unique per pawn. ShortName alone gives the class name, so two pawns of one class would collide.
      local id = e.full:match("%.([^%.%s]+)$") or ShortName(e.full)
      if not seen[id] then
        seen[id] = true
        local cls = e.full:match("^(%S+)") or "?"
        classes[cls] = (classes[cls] or 0) + 1
        local x, y, z = Pos(e.actor)
        local dead = IsDead(e.actor)
        if dead then deadNow = deadNow + 1 end
        local good = not IsOrigin(x, y, z)
        local rec = W.pawns[id]
        if rec then
          if good then rec.x, rec.y, rec.z = x, y, z end
        else
          if not coordTried then coordAddr = CoordAddress(); coordTried = true end
          if not good then x, y, z = nil, nil, nil end
          local door, doorDist = NearestDoor(x, y, z)
          local okP, proto = pcall(function() return e.actor:GetProtoName():ToString() end)
          if not okP then proto = nil end
          local counted, raw = Counted(e.actor, coordAddr)
          rec = { id = id, born = now, x = x, y = y, z = z, class = cls, proto = proto, dead = false }
          W.pawns[id] = rec
          -- Walk speed of the new pawn. Read in pcall; null when unreadable.
          local okSp, spd = pcall(function() return e.actor.CharacterMovement.MaxWalkSpeed end)
          WatchEmit("spawn", {
            id = id, class = cls, proto = NV(proto), x = NV(x), y = NV(y), z = NV(z),
            door = NV(door), doorDist = NV(doorDist), counted = NV(counted), coordRaw = NV(raw),
            health = NV(Health(e.actor)), speed = NV(okSp and spd or nil), inv = NV(DoorInv(door)),
          })
        end
        if dead and not rec.dead then
          WatchEmit("died", { id = id, x = NV(rec.x), y = NV(rec.y), z = NV(rec.z), life = now - rec.born, health = NV(Health(e.actor)),
            cause = DeathCause(rec.x, rec.y, rec.z) })
        end
        rec.dead = dead
      end
    end
    -- A pawn is gone after 2 passes in a row without its id. A pawn that returns after 1 missing pass keeps its record, so no new spawn.
    for id, rec in pairs(W.pawns) do
      if not seen[id] then
        W.missing[id] = (W.missing[id] or 0) + 1
        if W.missing[id] >= 2 then
          WatchEmit("gone", { id = id, x = NV(rec.x), y = NV(rec.y), z = NV(rec.z), life = now - rec.born })
          W.pawns[id] = nil
          W.missing[id] = nil
        end
      else
        W.missing[id] = nil
      end
    end
    if W.pass % 2 == 0 then
      local c = coordinator()
      local function get(name)
        if not c then return nil end
        local ok, v = pcall(function() return c[name](c) end)
        if ok then return v end
        return nil
      end
      local wave, wisp = nil, 0
      pcall(function()
        local gs = FindFirstOf("OMDGameState")
        if gs and gs:IsValid() then wave = gs.CurrentWave end
      end)
      pcall(function()
        for _, a in ipairs(FindAllOf("OMDAICharacter") or {}) do
          pcall(function()
            if a:IsValid() and a:GetFullName():find("BP_Wisp_") then wisp = wisp + 1 end
          end)
        end
      end)
      local iter = get("GetEndlessIteration")
      local key = tostring(wave or "?") .. "." .. tostring(iter or "?")
      if W.waveKey and W.waveKey ~= key then
        WatchEmit("wave", { from = W.waveKey, to = key })
        if WATCH_HITS then HitsDmRead() end
      end
      W.waveKey = key
      W.wave, W.iter = wave, iter -- read by the hit event
      DoorsTick()
      local brkNow = PhaseTick(wave, iter)
      HoardTick()
      PlayableTick()
      PauseTick(c)
      -- Player health, death and pawn (watch stream). A failed read gives php null. A failed death read counts as alive.
      -- A health of 0 or less counts as dead. ppawn is true when PlayerPawn() gives a pawn.
      -- W.pdead and W.ppawn keep the last value. A player event fires only when a value changes.
      local php, pdead, ppawn = nil, false, false
      local pxT, pyT, pzT = nil, nil, nil -- player location for the tick (#103)
      do
        local pp = PlayerPawn()
        if pp then
          ppawn = true
          pxT, pyT, pzT = Pos(pp)
          local okH, h = pcall(function() return pp:GetHealth() end)
          if okH and type(h) == "number" then php = h end
          pdead = IsDead(pp)
        end
        if type(php) == "number" and php <= 0 then pdead = true end
        if pdead and not W.pdead then
          WatchEmit("player", { state = "dead", hp = NV(php), round = REFORGED.round, wave = NV(wave) })
        elseif W.pdead and not pdead then
          WatchEmit("player", { state = "alive", hp = NV(php) })
        end
        W.pdead = pdead
        -- pawn means the pawn came back after a nopawn. The first pawn of a match gives no event.
        if W.ppawn == true and not ppawn then
          WatchEmit("player", { state = "nopawn", round = REFORGED.round, wave = NV(wave) })
          W.pawnLost = true
        elseif W.pawnLost and ppawn then
          W.pawnLost = false
          WatchEmit("player", { state = "pawn", hp = NV(php) })
        end
        W.ppawn = ppawn
      end
      -- game-end: gend is OMDGameState:GetIsGameEnded. A failed read or a non-boolean is unknown (JSON null).
      -- game-end is written once per map, the first time the flag reads true. W.gameEndSent is reset by WatchMapReady.
      local gend = nil
      do
        local okE, gsE = pcall(FindFirstOf, "OMDGameState")
        if okE and gsE then
          local okG, ended = pcall(function() return gsE:GetIsGameEnded() end)
          if okG and type(ended) == "boolean" then gend = ended end
          if gend == true and not W.gameEndSent then
            W.gameEndSent = true
            local riftE = nil
            pcall(function() riftE = gsE.RiftPoints end)
            local okM, modeE = pcall(QueueBlockMode)
            if not okM then modeE = nil end
            -- won is the native bDidWin flag. nil when the read fails or is not a boolean.
            local wonE = nil
            pcall(function() wonE = gsE.bDidWin end)
            if type(wonE) ~= "boolean" then wonE = nil end
            -- integrity is read only (#102). nil when the instance or the read is missing.
            local integE = nil
            pcall(function()
              local giE = ScoreBlockInstance()
              if giE then integE = giE:GetGameIntegrity() end
            end)
            if type(integE) ~= "number" then integE = nil end
            WatchEmit("game-end", { rift = NV(riftE), wave = NV(wave), mode = NV(modeE), won = NV(wonE), integrity = NV(integE) })
            print("[Reforged] game-end rift=" .. tostring(riftE) .. " wave=" .. tostring(wave) .. " mode=" .. tostring(modeE)
              .. " won=" .. tostring(wonE) .. " integrity=" .. tostring(integE))
          end
        end
      end
      local okWT, wispTick = pcall(WispTickFields)
      if not okWT or type(wispTick) ~= "table" then wispTick = {} end
      WatchEmit("tick", ReforgedTickFields({
        gend = NV(gend),
        wisps = NV(wispTick.count), wispLoc = NV(wispTick.loc),
        wave = NV(wave), iter = NV(iter), alive = NV(get("GetNumPawnsAlive")),
        waiting = NV(get("GetNumPawnsWaitingForSpawn")), approved = NV(get("GetNumPawnsApprovedForSpawn")),
        live = #list, dead = deadNow, standing = #list - deadNow, wisp = wisp, classes = classes,
        phase = NV(W.phase), brk = NV(brkNow.kind), timer = NV(brkNow.timer),
        qswap = QBLOCK.swapped, hold = TICK_HOLD == true, pq = #PACE_QUEUE,
        gtq = #GT_QUEUE, gtlate = GT_STATS.late,
        hitseen = WATCH_HITS and NV(HITS.seen) or nil, hitmatch = WATCH_HITS and NV(HITS.matched) or nil,
        php = NV(php), pdead = pdead, ppawn = ppawn,
        px = Round(pxT), py = Round(pyT), pz = Round(pzT),
      }))
    end
    if WATCH_TRACK_MS > 0 then
      local every = math.max(1, math.floor(WATCH_TRACK_MS / 500 + 0.5))
      if W.pass % every == 0 then
        local p = List({})
        -- hp and tg are read for the pawns of this pass's live list. A pawn missing from the list gives null.
        local byId, pAddr = {}, nil
        for _, e in ipairs(list) do
          byId[e.full:match("%.([^%.%s]+)$") or ShortName(e.full)] = e.actor
        end
        local pp = PlayerPawn()
        if pp then pcall(function() pAddr = pp:GetAddress() end) end
        for _, rec in pairs(W.pawns) do
          local hp, tg = nil, nil
          if byId[rec.id] then hp, tg = TrackReads(byId[rec.id], pAddr) end
          p[#p + 1] = { rec.id, Round(rec.x), Round(rec.y), Round(rec.z), rec.dead and 1 or 0, NV(hp), NV(tg) }
        end
        WatchEmit("track", { p = p })
      end
    end
  end

  -- Level name of the current map, the same source as the map event: the first spawner, else a live pawn.
  -- Returns nil when no name is found. Reads only; it is pcall-wrapped by the caller.
  function ReforgedMapLevel()
    local okL, spawners = pcall(FindAllOf, "OMDAISpawner")
    spawners = (okL and spawners) or {}
    for _, sp in ipairs(spawners) do
      local okF, full = pcall(function() return sp:GetFullName() end)
      if okF then
        local level = LevelFromFullName(full)
        if level then return level end
      end
    end
    for _, e in ipairs(LiveNonWispAI()) do
      local level = LevelFromFullName(e.full)
      if level then return level end
    end
    return nil
  end

  -- Called from both auto-test map-ready places. The door list is read here and kept for the nearest-door lookup.
  function WatchMapReady(missionName)
    pcall(ReforgedWispClearAuto, "map-ready") -- The auto wisps are destroyed first
    REFORGED_WISPS = {} -- The probe wisps die with the map
    W.phase, W.hoardKey, W.playableSent, W.paused = nil, nil, false, nil
    W.brk, W.seenCombat = nil, false
    W.gameEndSent = nil -- Game-end is written once per map
    W.pdead, W.ppawn, W.pawnLost = nil, nil, nil -- the player state starts over on a new map
    local ok, err = pcall(function()
      -- The FString from GetCurrentMissionLevelName may not convert. Keep it only when it is printable ASCII.
      local raw = nil
      local okS, s = pcall(function() return missionName:ToString() end)
      if okS and type(s) == "string" and s ~= "" and not s:find("[^\32-\126]") then raw = s end
      -- Level name: from the first spawner, else from the first live pawn. A spawner read works before doors are set.
      local okL, spawners = pcall(FindAllOf, "OMDAISpawner")
      spawners = (okL and spawners) or {}
      local level = nil
      for _, sp in ipairs(spawners) do
        local okF, full = pcall(function() return sp:GetFullName() end)
        if okF then level = LevelFromFullName(full) end
        if level then break end
      end
      if not level then
        for _, e in ipairs(LiveNonWispAI()) do
          level = LevelFromFullName(e.full)
          if level then break end
        end
      end
      local doors = {}
      for _, sp in ipairs(spawners) do
        local d = { actor = sp }
        pcall(function() d.i = sp.indexInLevel end)
        d.x, d.y, d.z = Pos(sp)
        doors[#doors + 1] = d
      end
      W.doors, W.pawns, W.doorsSent = doors, {}, false
      W.doorEv = {} -- #103 C2: the door event state starts over on a new map
      local fields = { level = NV(level), doors = DoorList() }
      -- The mode at map ready (MapReadyFor applied it first). The state line reads it from here.
      local okMd, md = pcall(QueueBlockMode)
      fields.mode = NV(okMd and md or nil)
      if raw then fields.levelRaw = raw end
      WatchEmit("map", fields)
    end)
    if not ok then WatchErr(err, "map") end
  end

  -- Map leave: drops the door actors of the old map, so DoorsTick reads no freed spawner. The x, y, z stay for DoorList.
  function WatchMapLeave()
    for _, d in ipairs(W.doors) do d.actor = nil end
    W.doorsSent = true
  end

  -- #103 C2: a door event is due when no door event went out for this door in an earlier pass. A pass is 500 ms, so a
  -- door sends at most one event per 0.5 s. Pure: no game read.
  function WatchDoorEventDue(lastPass, pass)
    return lastPass == nil or pass > lastPass
  end

  -- #103 C2: the door number of a door at x, y, z is the indexInLevel of the nearest spawner in W.doors. nil when none.
  function WatchDoorNumber(x, y, z)
    if x == nil then return nil end
    local best, bestD = nil, nil
    for _, sp in ipairs(W.doors) do
      if sp.x ~= nil and sp.i ~= nil then
        local dx, dy, dz = sp.x - x, sp.y - y, sp.z - z
        local dd = dx * dx + dy * dy + dz * dz
        if bestD == nil or dd < bestD then best, bestD = sp.i, dd end
      end
    end
    return best
  end

  -- #103 C2: reads each door of the preview door classes (all maps). Writes a door event at first sight and when Health
  -- or bIsOpen changes, at most once per pass. Reads only, every game read in pcall. max is GetMaxHealth, else the first
  -- Health read. open is 1 or 0.
  function WatchDoorsScan()
    W.doorEv = W.doorEv or {}
    local seen = {}
    for _, cls in ipairs(REFORGED_PREVIEW_DOOR_CLASSES) do
      local okF, found = pcall(FindAllOf, cls)
      for _, d in ipairs((okF and found) or {}) do
        local okV, valid = pcall(function() return d:IsValid() end)
        local okN, full = pcall(function() return d:GetFullName() end)
        if okV and valid == true and okN and type(full) == "string" and not seen[full] then
          seen[full] = true
          local hp, open = nil, nil
          pcall(function() hp = d.Health end)
          pcall(function() open = d.bIsOpen end)
          if type(hp) ~= "number" then hp = nil end
          if type(open) ~= "boolean" then open = nil end
          local openN = nil
          if open ~= nil then openN = open and 1 or 0 end
          local rec = W.doorEv[full]
          if rec == nil then
            rec = { seen = false }
            pcall(function() rec.max = d:GetMaxHealth() end)
            if type(rec.max) ~= "number" then rec.max = hp end
            W.doorEv[full] = rec
          end
          local changed = not rec.seen or rec.hp ~= hp or rec.open ~= openN
          if (hp ~= nil or openN ~= nil) and changed and WatchDoorEventDue(rec.lastPass, W.pass) then
            local x, y, z = Pos(d)
            WatchEmit("door", { i = NV(WatchDoorNumber(x, y, z)), hp = NV(hp), max = NV(rec.max), open = NV(openN) })
            rec.seen, rec.hp, rec.open, rec.lastPass = true, hp, openN, W.pass
          end
        end
      end
    end
  end

  -- Counted marker: raw Int64 at +0x848 on OMDAICharacter. Read only as a raw value, never as an object.
  W.markerOk = false
  if PropertyTypes and PropertyTypes.Int64Property ~= nil then
    local okR = pcall(RegisterCustomProperty, {
      Name = "ReforgedSpawnCoord", Type = PropertyTypes.Int64Property,
      BelongsToClass = "/Script/OMD.OMDAICharacter", OffsetInternal = 0x848,
    })
    W.markerOk = okR
  end
  print("[Reforged] watch counted-marker registered=" .. tostring(W.markerOk))

  -- Traceback handler for the watch pass. WatchErrText keeps the first traceback line that points into main.lua.
  function WatchTrace(e) return debug.traceback(tostring(e), 2) end
  function WatchErrText(err)
    local text = tostring(err)
    local head = text:match("^[^\n]*")
    local ref = text:match("\n([^\n]*main%.lua:%d+[^\n]*)") or text:match("([^\n]*main%.lua:%d+[^\n]*)")
    if ref then ref = ref:gsub("^%s+", "") end
    return ref and (head .. " [" .. ref .. "]") or head
  end

  GameLoop(500, function()
    if WATCH_ON then
      local ok, err = xpcall(Pass, WatchTrace)
      if not ok then WatchErr(WatchErrText(err)) end
    end
    return false
  end)
  print("[Reforged] watch stream " .. (WATCH_ON and "on" or "off") .. " (watch.jsonl, track " .. tostring(WATCH_TRACK_MS) .. " ms)")
end
-- END WATCH STREAM

-- hurt-player [amount]: test only. Applies a known damage to the player pawn, to prove the hit chain.
-- Route 1: the engine static ApplyDamage. Route 2: the OMD static ApplyDamage. Route none: both failed.
-- Health is read before, and 1 s later in the same delayed step. Does not change HitsBody. Sits outside the watch blocks.
function WatchHurtPlayer(amount)
  local pawn = WatchHurtContext()
  if not pawn then print("[Reforged] hurt-player: no player pawn"); return end
  local function Health()
    local h = nil
    pcall(function() local v = pawn:GetHealth(); if type(v) == "number" then h = v end end)
    return h
  end
  local hpBefore = Health()
  local route = "none"
  local okE = pcall(function()
    local gs = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    gs:ApplyDamage(pawn, amount, nil, nil, nil)
  end)
  if okE then route = "engine"
  else
    local okO = pcall(function()
      local gs = StaticFindObject("/Script/OMD.Default__OMDGameplayStatics")
      gs:ApplyDamage(pawn, amount, nil, nil, nil)
    end)
    if okO then route = "omd" end
  end
  GameDelay(1000, function()
    local hpAfter = Health()
    local _, seen, matched = WatchHurtContext()
    print(string.format("[Reforged] hurt-player amount=%s route=%s hpBefore=%s hpAfter=%s hitseen=%s hitmatch=%s",
      tostring(amount), route, tostring(hpBefore), tostring(hpAfter), tostring(seen), tostring(matched)))
    WatchEmit("hurt", { amount = amount, route = route, hpBefore = hpBefore or WatchNull, hpAfter = hpAfter or WatchNull })
  end)
end

-- rift-move [player | status | x y z]: test only. Moves the OMDRift and every path end point (0 NextPoints).
-- Target: the player pawn (default), or x y z. The Rift goes to target Z + dz, where dz = Rift Z - the nearest end point Z (200 when no end point).
-- Every function here is global, so the main chunk gets no new local. Every game call is in pcall.
function RiftVec(v)
  if v == nil then return nil end
  local ok, x, y, z = pcall(function() return v.X, v.Y, v.Z end)
  if ok and type(x) == "number" and type(y) == "number" and type(z) == "number" then return { X = x, Y = y, Z = z } end
  return nil
end

-- Location of an actor as { X, Y, Z }, or nil when the call or the read fails.
function RiftActorLoc(actor)
  local ok, v = pcall(function() return RiftVec(actor:K2_GetActorLocation()) end)
  if ok then return v end
  return nil
end

-- Valid OMDRift actors with a readable location. Returns a list of { actor, loc }.
function RiftList()
  local out = {}
  local okA, found = pcall(FindAllOf, "OMDRift")
  if okA and type(found) == "table" then
    for _, r in ipairs(found) do
      local okV, valid = pcall(function() return r:IsValid() == true end)
      local loc = nil
      if okV and valid then loc = RiftActorLoc(r) end
      if loc then out[#out + 1] = { actor = r, loc = loc } end
    end
  end
  return out
end

-- Path end points: valid OMDPathPoint with 0 NextPoints (read with pcall, not indexed). Returns a list of { actor, loc }.
function RiftEnds()
  local out = {}
  local okF, pts = pcall(FindAllOf, "OMDPathPoint")
  if okF and type(pts) == "table" then
    for _, p in ipairs(pts) do
      local okE, isEnd = pcall(function() return p:IsValid() == true and #p.NextPoints == 0 end)
      if okE and isEnd then
        local loc = RiftActorLoc(p)
        if loc then out[#out + 1] = { actor = p, loc = loc } end
      end
    end
  end
  return out
end

-- The list entry nearest to from in X and Y. nil when the list is empty.
function RiftNearestXY(list, from)
  local best, bestD = nil, nil
  for _, e in ipairs(list) do
    local dx, dy = e.loc.X - from.X, e.loc.Y - from.Y
    local d = dx * dx + dy * dy
    if bestD == nil or d < bestD then best, bestD = e, d end
  end
  return best
end

-- "x,y,z" with %.0f, or none.
function RiftFmt(v)
  if v == nil then return "none" end
  return string.format("%.0f,%.0f,%.0f", v.X, v.Y, v.Z)
end

-- Prints the rift-move line and emits the rift-move event. res holds result, source, rifts, from, to, read, area, dz, ends, endsMoved, endRead.
function RiftMoveReport(res)
  print(string.format("[Reforged] rift-move result=%s source=%s rifts=%d from=%s to=%s read=%s area=%s dz=%s ends=%d endsMoved=%d endRead=%s",
    res.result, res.source or "cmd", res.rifts, RiftFmt(res.from), RiftFmt(res.to), RiftFmt(res.read), RiftFmt(res.area),
    res.dz and string.format("%.0f", res.dz) or "none", res.ends, res.endsMoved, RiftFmt(res.endRead)))
  local function Axis(v, k) if v == nil then return WatchNull end return v[k] end
  WatchEmit("rift-move", {
    result = res.result, source = res.source or "cmd", rifts = res.rifts,
    fromX = Axis(res.from, "X"), fromY = Axis(res.from, "Y"), fromZ = Axis(res.from, "Z"),
    toX = Axis(res.to, "X"), toY = Axis(res.to, "Y"), toZ = Axis(res.to, "Z"),
    readX = Axis(res.read, "X"), readY = Axis(res.read, "Y"), readZ = Axis(res.read, "Z"),
    areaX = Axis(res.area, "X"), areaY = Axis(res.area, "Y"), areaZ = Axis(res.area, "Z"),
    dz = res.dz or WatchNull, ends = res.ends, endsMoved = res.endsMoved,
    endX = Axis(res.endRead, "X"), endY = Axis(res.endRead, "Y"), endZ = Axis(res.endRead, "Z"),
  })
end

-- After a Rift move, every lane link goes straight to the end point of its own path, so the behavior tree
-- (BTService_CheckForBestNode) cannot pick a lane toward the old Rift. Each non-end point gets its path's end
-- point (PointIndex). A point with no readable path, or whose path has no end, uses the only end point when there is
-- exactly one. A path with two or more ends gives no end. Only points with 1 to 6 NextPoints are changed.
-- Returns points, branches, failed. Globals only. Every game call is in pcall.
function RiftRewire()
  local points, branches, failed = 0, 0, 0
  local okF, all = pcall(FindAllOf, "OMDPathPoint")
  if not okF or type(all) ~= "table" then return points, branches, failed end
  local info = {}
  local endsByKey, endIdxByKey, endCount, onlyEndIdx = {}, {}, 0, nil
  for _, p in ipairs(all) do
    local okV, valid = pcall(function() return p:IsValid() == true end)
    if okV and valid then
      local okN, n = pcall(function() return #p.NextPoints end)
      local okK, key = pcall(function() return tostring(p.ParentPath:GetFullName()) end)
      if not okK then key = nil end
      local okI, idx = pcall(function() return p.PointIndex end)
      if not okI then idx = nil end
      if not okN then n = nil end
      info[#info + 1] = { p = p, n = n, key = key, idx = idx }
      if n == 0 then
        endCount = endCount + 1
        onlyEndIdx = idx
        if key ~= nil then
          endsByKey[key] = (endsByKey[key] or 0) + 1
          endIdxByKey[key] = idx
        end
      end
    end
  end
  for _, e in ipairs(info) do
    if e.n ~= nil and e.n >= 1 and e.n <= 6 then
      local endIdx = nil
      if e.key ~= nil and endsByKey[e.key] == 1 then endIdx = endIdxByKey[e.key]
      elseif endCount == 1 then endIdx = onlyEndIdx
      end
      if endIdx ~= nil then
        local here = 0
        for i = 1, e.n do
          local okB, br = pcall(function() return e.p.NextPoints[i] end)
          local okW = okB and pcall(function() br.PointIndex = endIdx end)
          local okR, got = pcall(function() return br.PointIndex end)
          if okW and okR and got == endIdx then
            here = here + 1
          else
            failed = failed + 1
          end
        end
        branches = branches + here
        if here > 0 then points = points + 1 end
      end
    end
  end
  return points, branches, failed
end

-- rift-move target: "player" or {X,Y,Z}. Moves the first valid Rift and each end point. Reports through RiftMoveReport.
-- source is "cmd" (default, the developer command) or "key" (F7). Returns the result text.
function RiftMove(target, source)
  local res = { result = "no-rift", source = source or "cmd", rifts = 0, ends = 0, endsMoved = 0 }
  local rifts = RiftList()
  res.rifts = #rifts
  if #rifts == 0 then RiftMoveReport(res); return res.result end
  local P = nil
  if target == "player" then
    local okP, pawn = pcall(WatchHurtContext)
    if okP and pawn then P = RiftActorLoc(pawn) end
    if P == nil then res.result = "no-player"; RiftMoveReport(res); return res.result end
  else
    P = target
  end
  local rift = rifts[1]
  res.from = rift.loc
  local ends = RiftEnds()
  res.ends = #ends
  local endNear = RiftNearestXY(ends, rift.loc)
  res.dz = endNear and (rift.loc.Z - endNear.loc.Z) or 200
  local T = { X = P.X, Y = P.Y, Z = P.Z + res.dz }
  res.to = T
  local okSet = pcall(function() rift.actor:K2_SetActorLocation({ X = T.X, Y = T.Y, Z = T.Z }, false, {}, true) end)
  res.read = RiftActorLoc(rift.actor)
  local okArea, area = pcall(function() return rift.actor.RiftEnterArea:K2_GetComponentLocation() end)
  if okArea then res.area = RiftVec(area) end
  local routeEnd = nil -- The first end point that moved. The direct route goes to it.
  for _, e in ipairs(ends) do
    local okM = pcall(function() e.actor:K2_SetActorLocation({ X = P.X, Y = P.Y, Z = P.Z }, false, {}, true) end)
    if okM then
      res.endsMoved = res.endsMoved + 1
      if routeEnd == nil then routeEnd = e.actor end
    end
  end
  if ends[1] then res.endRead = RiftActorLoc(ends[1].actor) end
  if REFORGED_RULES then REFORGED_RULES.riftLocs = nil end
  local near = false
  if res.read then
    local dist = math.sqrt((res.read.X - T.X) ^ 2 + (res.read.Y - T.Y) ^ 2 + (res.read.Z - T.Z) ^ 2)
    near = dist <= 50
  end
  if not okSet then res.result = "fail"
  elseif near and res.endsMoved == #ends then res.result = "ok"
  else res.result = "partial" end
  RiftMoveReport(res)
  if res.result == "ok" then
    -- After a good move, live enemies take a direct route to the new end point (RiftRouteStep).
    RIFT_ROUTE.on = true
    RIFT_ROUTE.endPoint = routeEnd
    RIFT_ROUTE.done = {}
    -- The lane graph goes to the new end point first, so the behavior tree keeps the direct route.
    local okRW, rwP, rwB, rwF = pcall(RiftRewire)
    if not okRW then rwP, rwB, rwF = 0, 0, 0 end
    print(string.format("[Reforged] rift-rewire points=%d branches=%d failed=%d", rwP, rwB, rwF))
    WatchEmit("rift-rewire", { points = rwP, branches = rwB, failed = rwF })
    pcall(RiftRouteStep)
    -- The next player pawn (a respawn) goes to P, where the player stood.
    local okPK, pkey = pcall(function() local pw = WatchHurtContext(); if pw then return PawnKey(pw) end return nil end)
    RIFT_RESPAWN.on = true
    RIFT_RESPAWN.P = { X = P.X, Y = P.Y, Z = P.Z }
    RIFT_RESPAWN.rift = rifts[1].actor
    RIFT_RESPAWN.pawnKey = okPK and pkey or nil
  end
  return res.result
end

-- F7: moves the Rift to the player. Runs on the game thread (GameLoop). Only before the first combat on this map,
-- and only when the player stands on the ground. Every other press prints its result and shows a banner (except no-player).
-- source is "key" (F7, the default) or "pad" (LB + RB). It is the source field of every report.
function RiftMoveKey(source)
  local src = source or "key"
  local function Refuse(result, text)
    local rifts = 0
    local okL, list = pcall(RiftList)
    if okL and list then rifts = #list end
    RiftMoveReport({ result = result, source = src, rifts = rifts, ends = 0, endsMoved = 0 })
    if text then pcall(HudBannerShow, text, nil) end
  end
  if WatchSeenCombat() then
    Refuse("late", "RIFT MOVES ONLY BEFORE THE FIRST WAVE")
    return
  end
  local pawn = WatchHurtContext()
  if pawn == nil then
    Refuse("no-player", nil)
    return
  end
  local okG, grounded = pcall(function() return pawn.CharacterMovement:IsMovingOnGround() end)
  if okG and grounded == false then
    Refuse("air", "STAND ON THE GROUND")
    return
  end
  local result = RiftMove("player", src)
  if result == "ok" then pcall(HudBannerShow, "RIFT MOVED", nil) end
end

-- Direct route. After a good Rift move, each live non-Wisp enemy skips the authored lanes: its path is rebuilt
-- (LoadPathFromLevel) and its next point is set to the new end point (SetStartPoint). Off until a good move.
-- Globals only. Every game call is in pcall. At most 40 pawns get a controller call per RiftRouteStep call.
RIFT_ROUTE = RIFT_ROUTE or { on = false, endPoint = nil, done = {} }

function RiftRouteStep()
  if RIFT_ROUTE.on ~= true then return end
  local endPoint = RIFT_ROUTE.endPoint
  local okV, valid = pcall(function() return endPoint ~= nil and endPoint:IsValid() == true end)
  if not okV or not valid then
    RIFT_ROUTE.on = false
    RIFT_ROUTE.endPoint = nil
    RIFT_ROUTE.done = {}
    return
  end
  local routed, failed, handled = 0, 0, 0
  for _, e in ipairs(LiveNonWispAI()) do
    if handled >= 40 then break end
    if not RIFT_ROUTE.done[e.full] then
      local okD, dead = pcall(function() return e.actor.bIsDead == true end)
      if not (okD and dead) then
        local ctrl = nil
        local okC, c = pcall(function() return e.actor.Controller end)
        if okC and c ~= nil then ctrl = c
        else
          local okG, g = pcall(function() return e.actor:GetController() end)
          if okG and g ~= nil then ctrl = g end
        end
        -- No controller: skip it and leave it not done, so a later call can route it.
        if ctrl ~= nil then
          handled = handled + 1
          pcall(function() ctrl:LoadPathFromLevel() end)
          local okS = pcall(function() ctrl:SetStartPoint(endPoint) end)
          if okS then routed = routed + 1 else failed = failed + 1 end
          RIFT_ROUTE.done[e.full] = true
        end
      end
    end
  end
  if routed + failed > 0 then
    local total = 0
    for _ in pairs(RIFT_ROUTE.done) do total = total + 1 end
    print(string.format("[Reforged] rift-route routed=%d failed=%d total=%d", routed, failed, total))
    WatchEmit("rift-route", { routed = routed, failed = failed, total = total })
  end
end

GameLoop(500, function() pcall(RiftRouteStep); return false end)

-- After a successful Rift move, the next player pawn (a respawn) is moved to P, the place where the player
-- stood when the Rift moved. Before any move, nothing changes. RiftRespawnStep runs every 500 ms on the game thread.
-- Globals only. Every game call is in pcall.
RIFT_RESPAWN = RIFT_RESPAWN or { on = false, P = nil, rift = nil, pawnKey = nil }

-- Key of a pawn for "same pawn or new pawn": the address, else the full name. Nil when neither reads.
function PawnKey(pawn)
  local okA, addr = pcall(function() return pawn:GetAddress() end)
  if okA and addr ~= nil then return tostring(addr) end
  local okN, name = pcall(function() return pawn:GetFullName() end)
  if okN and name ~= nil then return tostring(name) end
  return nil
end

function RiftRespawnStep()
  if RIFT_RESPAWN.on ~= true then return end
  local rift = RIFT_RESPAWN.rift
  local okV, valid = pcall(function() return rift ~= nil and rift:IsValid() == true end)
  if not okV or not valid then
    RIFT_RESPAWN.on = false
    RIFT_RESPAWN.P = nil
    RIFT_RESPAWN.rift = nil
    RIFT_RESPAWN.pawnKey = nil
    return
  end
  local okP, pawn = pcall(WatchHurtContext)
  if not okP or pawn == nil then return end
  local key = PawnKey(pawn)
  if key == nil or key == RIFT_RESPAWN.pawnKey then return end
  RIFT_RESPAWN.pawnKey = key
  local P = RIFT_RESPAWN.P
  local T = { X = P.X, Y = P.Y, Z = P.Z + 20 }
  local ok1, moved = pcall(function() return pawn:K2_TeleportTo(T, pawn:K2_GetActorRotation()) end)
  local route = "none"
  if ok1 and moved then route = "teleport" end
  if not (ok1 and moved) then
    local ok2 = pcall(function() pawn:K2_SetActorLocation(T, false, {}, true) end)
    if ok2 then route = "set" end
  end
  local okR, read = pcall(function() return RiftVec(pawn:K2_GetActorLocation()) end)
  if not okR then read = nil end
  local dist = nil
  if read then dist = math.sqrt((read.X - T.X) ^ 2 + (read.Y - T.Y) ^ 2 + (read.Z - T.Z) ^ 2) end
  local result = (dist ~= nil and dist <= 300) and "ok" or "fail"
  print(string.format("[Reforged] respawn-move result=%s route=%s x=%s y=%s z=%s dist=%s", result, route,
    read and string.format("%.0f", read.X) or "none", read and string.format("%.0f", read.Y) or "none",
    read and string.format("%.0f", read.Z) or "none", dist and string.format("%.0f", dist) or "none"))
  WatchEmit("respawn-move", {
    result = result, route = route,
    x = read and read.X or WatchNull, y = read and read.Y or WatchNull, z = read and read.Z or WatchNull,
    dist = dist or WatchNull,
  })
end

GameLoop(500, function() pcall(RiftRespawnStep); return false end)

-- Gamepad shoulder probe. UE4SS RegisterKeyBind reads keyboard keys only. This probe checks whether
-- APlayerController:IsInputKeyDown reads the controller shoulders from Lua. It runs only in test mode.
-- lb and rb hold the state text "down", "up", "err", or nil before the first read.
PAD_PROBE = PAD_PROBE or { lb = nil, rb = nil, errLogged = false, calls = 0 }
-- Returns ok, down, err. ok is false when the call raises or does not return a boolean. err holds the message.
function PadKeyDown(pc, keyName)
  local ok, res = pcall(function()
    return pc:IsInputKeyDown({ KeyName = FName(keyName, EFindName.FNAME_Add) })
  end)
  if not ok then return false, nil, tostring(res) end
  if res == true or res == false then return true, res, nil end
  return false, nil, "non-boolean result " .. type(res)
end

function PadProbeStep()
  if TESTING ~= true then return end
  local okF, pc = pcall(function() return FindFirstOf("OMDPlayerController") end)
  if not okF or not pc then return end
  local okV, valid = pcall(function() return pc:IsValid() end)
  if not okV or valid ~= true then return end
  local P = PAD_PROBE
  local function read(name)
    P.calls = P.calls + 1
    local ok, down, err = PadKeyDown(pc, name)
    if not ok then
      if not P.errLogged then
        P.errLogged = true
        print(string.format("[Reforged] pad-probe err key=%s err=%s", name, tostring(err)))
      end
      return "err"
    end
    return down and "down" or "up"
  end
  local lbS = read("Gamepad_LeftShoulder")
  local rbS = read("Gamepad_RightShoulder")
  if lbS == P.lb and rbS == P.rb then return end
  P.lb, P.rb = lbS, rbS
  print(string.format("[Reforged] pad-probe LB=%s RB=%s calls=%d", lbS, rbS, P.calls))
  local function bv(s)
    if s == "down" then return true elseif s == "up" then return false end
    return WatchNull
  end
  WatchEmit("pad", { lb = bv(lbS), rb = bv(rbS) })
end

GameLoop(100, function() pcall(PadProbeStep); return false end)

-- rift-move status: prints the first Rift and the end point nearest to it. Moves nothing.
function RiftStatus()
  local rifts = RiftList()
  local ends = RiftEnds()
  local rift = rifts[1]
  local endNear = nil
  if rift then endNear = RiftNearestXY(ends, rift.loc) end
  print(string.format("[Reforged] rift-status rifts=%d rift=%s ends=%d end=%s",
    #rifts, rift and RiftFmt(rift.loc) or "none", #ends, endNear and RiftFmt(endNear.loc) or "none"))
end

-- Direct-spawn probe. Modes: "guid" passes the GUID-table proto to
-- SpawnEntityForEntity; "self" passes the controlling pawn's own game-owned
-- protodata to SpawnEntityForEntity; "from" passes that protodata to
-- SpawnEntityFromEntity (no position argument). rank picks the Nth-nearest
-- live non-Wisp pawn to the door as ControllingCharacter. The out array cannot
-- be read back from Lua, so spawned pawns are found by diffing the live set.
local probeId = 0
local function ProbeSpawn(mode, row, count, doorIndex, rank)
  probeId = probeId + 1
  local id = probeId
  ExecuteInGameThread(function()
    local c = coordinator()
    if not c then print("[Reforged] probe #" .. id .. " aborted: no coordinator"); return end
    local door, why = DoorTransform(doorIndex)
    if not door then print("[Reforged] probe #" .. id .. " rejected: " .. tostring(why)); return end
    local live = LiveNonWispAI()
    for _, e in ipairs(live) do e.dist = DistanceTo(e.actor, door.loc) end
    table.sort(live, function(a, b) return a.dist < b.dist end)
    local entity = live[rank]
    if not entity then
      print(string.format("[Reforged] probe #%d aborted: rank %d needs %d live non-Wisp AI characters, found %d",
        id, rank, rank, #live))
      return
    end
    local proto
    if mode == "guid" then
      proto = { Guid = row.guid }
    else
      local okP, own = pcall(function() return entity.actor.protodata end)
      if not okP or own == nil then
        print(string.format("[Reforged] probe #%d aborted: controlling pawn protodata unreadable (%s)",
          id, tostring(own)))
        return
      end
      proto = own
    end
    local okLoc, ctrlLoc = pcall(function() return entity.actor:K2_GetActorLocation() end)
    local before = {}
    for _, e in ipairs(live) do before[e.full] = true end
    print(string.format("[Reforged] probe #%d mode=%s proto=%s x%d door=%d rank=%d ctrl=%s ctrlLoc=%s doorLoc=%s ctrlDoorDist=%.0f",
      id, mode, mode == "guid" and row.name or "controller-protodata", count, doorIndex, rank,
      ShortName(entity.full), okLoc and Vec(ctrlLoc) or "?", Vec(door.loc), entity.dist))
    local okCall, ret = pcall(function()
      if mode == "from" then
        return c:SpawnEntityFromEntity(entity.actor, proto, count, {})
      end
      return c:SpawnEntityForEntity(entity.actor, door.loc, door.rot, proto, count, false, {})
    end)
    print(string.format("[Reforged] probe #%d call ok=%s return=%s %s",
      id, tostring(okCall), tostring(ret), population(c)))
    local samples = 0
    GameLoop(1500, function()
      samples = samples + 1
      local now = coordinator()
      local fresh = {}
      for _, e in ipairs(LiveNonWispAI()) do
        if not before[e.full] then
          local okL, loc = pcall(function() return e.actor:K2_GetActorLocation() end)
          if okL then
            fresh[#fresh + 1] = string.format("%s@%s dDoor=%.0f dCtrl=%s",
              ShortName(e.full), Vec(loc), DistanceTo(e.actor, door.loc),
              okLoc and string.format("%.0f", DistanceTo(e.actor, ctrlLoc)) or "?")
          end
        end
      end
      print(string.format("[Reforged] probe #%d +%.1fs %s new=%d [%s]",
        id, samples * 1.5, now and population(now) or "no coordinator", #fresh,
        #fresh > 0 and table.concat(fresh, "; ", 1, math.min(#fresh, 8)) or "none"))
      return samples >= 5
    end)
  end)
end

-- Door spawn through the native door spawner (AOMDAISpawner). Diagnostic
-- version: every field write and readback is logged on its own line, so a
-- failed step is visible, and each stock value is restored in its own pcall.
local function FieldText(obj, name)
  local ok, v = pcall(function() return obj[name] end)
  return ok and tostring(v) or "error"
end

local GUID_KEYS = { "A", "B", "C", "D" }

local function ProtoText(obj)
  local parts = {}
  for _, k in ipairs(GUID_KEYS) do
    local ok, v = pcall(function() return obj.SpawnProtodata.Guid[k] end)
    parts[#parts + 1] = k .. "=" .. (ok and tostring(v) or "error")
  end
  return table.concat(parts, " ")
end

local function DoorRead(doorIndex)
  ExecuteInGameThread(function()
    local spawner = FindSpawnerByIndex(doorIndex)
    if not spawner then
      print("[Reforged] door-read rejected: no spawner with indexInLevel " .. tostring(doorIndex))
      return
    end
    print(string.format("[Reforged] door-read %d min=%s max=%s maxAlive=%s active=%s currentAlive=%s proto[%s]",
      doorIndex, FieldText(spawner, "MinSpawnCount"), FieldText(spawner, "MaxSpawnCount"),
      FieldText(spawner, "MaxAliveCount"), FieldText(spawner, "bIsActive"),
      FieldText(spawner, "CurrentAliveCount"), ProtoText(spawner)))
  end)
end

-- Game-thread work queue. UE4SS dropped queued ExecuteInGameThread callbacks: a paced door call
-- left the pace queue, but its callback never ran. Callers use RunOnGameThread. GtPump runs every 50 ms on the game
-- thread (GameLoop) and drains the queue in order. GT_ON_THREAD is true in every game-thread callback, so RunOnGameThread
-- calls the job at once there.
do
  GT_QUEUE = GT_QUEUE or {}
  GT_STATS = GT_STATS or { queued = 0, run = 0, errors = 0, late = 0 }
  GT_ON_THREAD = GT_ON_THREAD or false
  GT_SEQ = GT_SEQ or 0
  GT_RUN_SEQ = GT_RUN_SEQ or 0
  GT_LATE_SECONDS = 5
  GT_DRAIN_MAX = 50

  -- Runs one job in pcall. A failure is printed, and the next job still runs.
  local function GtRunItem(item)
    GT_STATS.run = GT_STATS.run + 1
    if item.seq and item.seq > GT_RUN_SEQ then GT_RUN_SEQ = item.seq end
    local ok, err = pcall(item.fn)
    if not ok then
      GT_STATS.errors = GT_STATS.errors + 1
      print(string.format("[Reforged] gt-job error label=%s err=%s", tostring(item.label), tostring(err)))
    end
  end

  -- Drains up to GT_DRAIN_MAX jobs in order. The flag is reset even when a job raises.
  -- A job that waits more than GT_LATE_SECONDS is printed once. It still runs when the pump reaches it.
  function GtPump()
    GT_ON_THREAD = true
    -- A per-map job from an older map epoch is dropped, not run. It is removed in place. One line per pass.
    local gtDropped, gtOldest = 0, nil
    for i = #GT_QUEUE, 1, -1 do
      local item = GT_QUEUE[i]
      if item.any ~= true and item.epoch ~= (MAP_EPOCH or 0) then
        table.remove(GT_QUEUE, i)
        gtDropped = gtDropped + 1
        if gtOldest == nil or item.epoch < gtOldest then gtOldest = item.epoch end
      end
    end
    if gtDropped > 0 then
      print(string.format("[Reforged] map change: dropped %d game-thread job(s) from epoch %d", gtDropped, gtOldest))
    end
    local now = os.clock()
    for _, item in ipairs(GT_QUEUE) do
      local waited = now - item.at
      if waited > GT_LATE_SECONDS and not item.late then
        item.late = true
        GT_STATS.late = GT_STATS.late + 1
        print(string.format("[Reforged] gt-job late label=%s waited=%.1f", tostring(item.label), waited))
      end
    end
    pcall(function()
      local n = 0
      while #GT_QUEUE > 0 and n < GT_DRAIN_MAX do
        n = n + 1
        GtRunItem(table.remove(GT_QUEUE, 1))
      end
    end)
    GT_ON_THREAD = false
  end
  GameLoop(50, GtPump)

  -- Queues fn for the game thread. On the game thread (GT_ON_THREAD) it runs fn now and queues nothing.
  -- Any == true marks a job that runs on any map. Other jobs carry the map epoch they were queued in.
  function RunOnGameThread(label, fn, any)
    if GT_ON_THREAD then
      GtRunItem({ label = label, fn = fn })
      return
    end
    GT_SEQ = GT_SEQ + 1
    GT_QUEUE[#GT_QUEUE + 1] = { label = label, fn = fn, at = os.clock(), seq = GT_SEQ,
      epoch = MAP_EPOCH or 0, any = (any == true) }
    GT_STATS.queued = GT_STATS.queued + 1
  end

end

-- Runs fn once after ms milliseconds. The scheduler runs on the game thread (GameLoop), not on the async thread.
-- One scheduler serves all After calls. Each call adds an item to AFTER_QUEUE. One GameLoop(100) runs
-- the due items. Before, each call made its own loop, and that added to the game-thread callback load.
AFTER_QUEUE = AFTER_QUEUE or {}
-- Each item keeps the map epoch it was queued in. The pass below drops a per-map item from an older epoch.
local function After(ms, fn)
  AFTER_QUEUE[#AFTER_QUEUE + 1] = { ticks = math.max(1, math.ceil(ms / 100)), fn = fn, epoch = MAP_EPOCH or 0 }
end
-- Like After, but the item runs on any map (menu, log-only and command jobs).
function AfterAny(ms, fn)
  AFTER_QUEUE[#AFTER_QUEUE + 1] = { ticks = math.max(1, math.ceil(ms / 100)), fn = fn, epoch = MAP_EPOCH or 0, any = true }
end
AfterForTest = After -- the offline test calls this alias; the game does not use it
-- Deferred step for the watch-hits h2 read. The watch block sits above After, so it calls this global.
function WatchHitsDefer(ms, fn) After(ms, fn) end
GameLoop(100, function()
  if #AFTER_QUEUE == 0 then return false end
  -- A per-map item from an older map epoch is dropped, due or not. It is not run. One line per pass.
  do
    local kept, dropped, oldest = {}, 0, nil
    for _, item in ipairs(AFTER_QUEUE) do
      if item.any ~= true and item.epoch ~= (MAP_EPOCH or 0) then
        dropped = dropped + 1
        if oldest == nil or item.epoch < oldest then oldest = item.epoch end
      else
        kept[#kept + 1] = item
      end
    end
    AFTER_QUEUE = kept
    if dropped > 0 then
      print(string.format("[Reforged] map change: dropped %d delayed job(s) from epoch %d", dropped, oldest))
    end
  end
  if #AFTER_QUEUE == 0 then return false end
  -- Due items are taken out of the queue before any of them runs. An fn that calls After queues its item for a later pass.
  local due, keep = {}, {}
  for _, item in ipairs(AFTER_QUEUE) do
    item.ticks = item.ticks - 1
    if item.ticks <= 0 then due[#due + 1] = item else keep[#keep + 1] = item end
  end
  AFTER_QUEUE = keep
  for _, item in ipairs(due) do
    local ok, err = pcall(item.fn)
    if not ok then print("[Reforged] delayed step error: " .. tostring(err)) end
  end
  return false
end)

-- Releases held spawn calls once the hoard is released. The queue is cleared first, so a call held again goes into a new queue.
-- Held calls run 10 s apart. Each pass also runs the automatic tick hold, so the hold does not depend on a held call.
-- TICK_HOLD_UNTIL is set before the calls are scheduled, so the hold is on before the round can end between two released calls.
GameLoop(1000, function()
  -- GT_ON_THREAD marks this pass. A door call that the pass makes (PaceStep) runs at once, not from the game-thread queue.
  local function pass()
    pcall(TickHoldAutoStep)
    pcall(ReforgedStep)
    pcall(ReforgedBossStep)
    pcall(ReforgedBearerStep)
    pcall(ReforgedRulesStep)
    pcall(ReforgedBreakStep)
    pcall(ReforgedWispStep)
    pcall(PaceStep)
    if #HOARD_HELD == 0 then return end
    if not HoardReleased() then return end
    local held = HOARD_HELD
    HOARD_HELD = {}
    print(string.format("[Reforged] spawn release: hoard released, held=%d", #held))
    local paced = QueueBlockActive()
    if paced and TICK_HOLD_AUTO == true then
      TICK_HOLD_UNTIL = os.time() + SPAWN_GAP * #held + 5
      pcall(TickHoldAutoStep)
    end
    -- In a queue-block mode the pace queue spaces the calls, so they run with no extra gap.
    for i, fn in ipairs(held) do
      if paced then After(0, fn) else After((i - 1) * 10000, fn) end
    end
  end
  GT_ON_THREAD = true
  local okPass, errPass = pcall(pass)
  GT_ON_THREAD = false
  if not okPass then print("[Reforged] hoard pass error: " .. tostring(errPass)) end
  return false
end)
-- Break order fast check: every 50 ms, only while a watch is set (ReforgedBreakFastStep).
GameLoop(50, function() pcall(ReforgedBreakFastStep) return false end)

-- Director wave tracking. A wave is every pawn added by door calls after WaveBegin.
-- The wave ends when no tracked pawn is valid and no new spawn has happened for 12 s.
-- Assumption to verify in game: a killed pawn becomes invalid.
local waveTrack = { active = false, label = "", pawns = {}, lastSpawn = 0, scheduleEnd = 0 }
WAVE_HOLD = WAVE_HOLD or { on = false, stock = nil }
-- Hold the game's Next wave countdown while a director wave is open or any director pawn is alive: the coordinator counts only its own
-- pawns, so it announced waves as over with director orcs still on the map. DefaultWaveTimer is read when a break starts, so a break that
-- starts during the hold lasts up to 900 s (press G or Start next round once the map is clear). A manual OnslaughtGoBreak(4) on release was removed: it did not start a wave and the game crashed 2 min later.
local function WaveHoldCheck()
  if not TESTING then
    if WAVE_HOLD.on then
      local c = coordinator()
      if c and WAVE_HOLD.stock ~= nil then pcall(function() c.DefaultWaveTimer = WAVE_HOLD.stock end) end
      WAVE_HOLD.on = false
      print("[Reforged] wave-hold off: testing mode is off")
    end
    return
  end
  pcall(function()
    local c = coordinator()
    if not c then return end
    local aliveD = 0
    for _, actor in pairs(waveTrack.pawns) do
      local okV, valid = pcall(function() return actor:IsValid() end)
      if okV and valid then aliveD = aliveD + 1 end
    end
    local want = waveTrack.active or aliveD > 0
    if want and not WAVE_HOLD.on then
      WAVE_HOLD.stock = c.DefaultWaveTimer; c.DefaultWaveTimer = 900; WAVE_HOLD.on = true
      print(string.format("[Reforged] wave-hold on: DefaultWaveTimer %s -> 900 readback=%s (wave open=%s, %d director pawns alive)", tostring(WAVE_HOLD.stock), tostring(c.DefaultWaveTimer), tostring(waveTrack.active), aliveD))
    elseif not want and WAVE_HOLD.on then
      c.DefaultWaveTimer = WAVE_HOLD.stock; WAVE_HOLD.on = false
      print(string.format("[Reforged] wave-hold off: DefaultWaveTimer restored to %s readback=%s", tostring(WAVE_HOLD.stock), tostring(c.DefaultWaveTimer)))
    end
  end)
end
local function WaveBegin(label, scheduledDuration)
  waveTrack.active = true
  waveTrack.label = label
  -- A new wave must not forget pawns of the previous one that are still on the map (the old reset let a wave end with 2 bosses alive).
  local carried = {}
  for key, actor in pairs(waveTrack.pawns or {}) do
    local ok, valid = pcall(function() return actor:IsValid() end)
    if ok and valid then carried[key] = actor end
  end
  waveTrack.pawns = carried
  waveTrack.lastType = {}
  waveTrack.gone = {}
  waveTrack.lastSpawn = 0
  waveTrack.scheduleEnd = os.time() + math.max(0, tonumber(scheduledDuration) or 0)
  print("[Reforged] wave begin: " .. label)
  WatchEmit("dwave", { phase = "begin", label = tostring(label) })
  WaveHoldCheck()
end
local function WaveAlive()
  local alive = 0
  for key, actor in pairs(waveTrack.pawns) do
    local ok, valid = pcall(function() return actor:IsValid() end)
    if ok and valid then
      alive = alive + 1
      -- DeathType is read while the pawn is alive. Log changes, so the value
      -- before removal is recorded even when the pawn disappears.
      -- Read the object's name, not its address, so the death type is visible.
      -- Check validity first: GetFName on a null DeathType is a native read at 0x18 that pcall cannot catch
      -- (crashed OMD with EXCEPTION_ACCESS_VIOLATION 0x18, 2026-10-12 10:38 and 10:47 UTC).
      local okD, deathObj = pcall(function() return actor.DeathType end)
      local okV, deathValid = false, false
      if okD and deathObj then okV, deathValid = pcall(function() return deathObj:IsValid() end) end
      local okT, dt = false, nil
      if okV and deathValid then
        okT, dt = pcall(function() return deathObj:GetFName():ToString() end)
      end
      dt = okT and tostring(dt) or (okD and deathObj and okV and not deathValid and "none" or "unreadable")
      if dt ~= waveTrack.lastType[key] then
        print(string.format("[Reforged] wave pawn %s DeathType=%s", key, dt))
        waveTrack.lastType[key] = dt
      end
    elseif not waveTrack.gone[key] then
      waveTrack.gone[key] = true
      print(string.format("[Reforged] wave pawn gone %s lastDeathType=%s", key, tostring(waveTrack.lastType[key])))
    end
  end
  return alive, 0
end
local waveMonitorStarted = false
local function StartWaveMonitor()
  if waveMonitorStarted then return end
  waveMonitorStarted = true
  GameLoop(2000, function()
    do
      local function gtBody()
        WaveHoldCheck()
        if not waveTrack.active then return end
        local alive = WaveAlive()
        local now = os.time()
        local quiet = waveTrack.lastSpawn > 0 and (now - waveTrack.lastSpawn) or 0
        local scheduleFinished = now >= waveTrack.scheduleEnd
        local quietAfterSchedule = waveTrack.lastSpawn > 0 and quiet >= 12
        local emptyWaveTimedOut = waveTrack.lastSpawn == 0 and scheduleFinished and now - waveTrack.scheduleEnd >= 12
        -- The map must be clear: any live non-Wisp pawn (tracked or not) keeps the wave open.
        local onMap = #LiveNonWispAI()
        if alive == 0 and onMap == 0 and scheduleFinished and (quietAfterSchedule or emptyWaveTimedOut) then
          local total = 0
          for _ in pairs(waveTrack.pawns) do total = total + 1 end
          print(string.format("[Reforged] wave end: %s pawns tracked=%d alive=0 quiet=%ds", waveTrack.label, total, quiet))
          WatchEmit("dwave", { phase = "end", label = tostring(waveTrack.label), tracked = total, quiet = quiet })
          waveTrack.active = false
          if waveTrack.onEnd then local cb = waveTrack.onEnd; waveTrack.onEnd = nil; pcall(cb) end
        end
      end
      gtBody()
    end
    return false
  end)
end

if SPAWN_CENTER == nil then SPAWN_CENTER = true end -- true by default (measured: stock false spawns bosses 400+ units under the door). nil = leave the spawner alone; true/false is written to bSpawnAtCenter before each door call (spawn-center command)
-- Spawn pacing. In a queue-block mode (Manual now, Reforged later) a director door call waits in PACE_QUEUE.
-- PaceStep releases one call per SPAWN_GAP seconds. It also waits while the standing director pawns plus the call exceed SPAWN_CAP.
-- Classic never queues. SPAWN_GAP and SPAWN_CAP come from the settings rows spawnSpacingSeconds and activeEnemyBudget.
SPAWN_GAP = 10
SPAWN_CAP = nil -- nil = no cap
PACE_QUEUE = {}
PACE = { lastCall = 0, bypass = false }
-- The count of director pawns that are not dead. A failed read counts as alive (PawnIsDead).
function StandingCount()
  local n = 0
  for _, e in ipairs(LiveNonWispAI()) do
    if not PawnIsDead(e.actor) then n = n + 1 end
  end
  return n
end
-- Queues a door call in a queue-block mode and returns true. Returns false when the call may run now (Classic, or PaceStep is running it).
-- force: a Classic modifier call queues even though Classic never queues. A PaceStep release (PACE.bypass) never queues again.
function PaceHold(what, count, repeatCall, force)
  if PACE.bypass == true or not (force == true or QueueBlockActive()) then return false end
  PACE_QUEUE[#PACE_QUEUE + 1] = { what = what, count = tonumber(count) or 1, call = repeatCall, since = os.time(), waitNoted = false }
  print(string.format("[Reforged] spawn paced: queued=%d what=%s", #PACE_QUEUE, what))
  return true
end
-- One release check. Called once per pass from the hoard release loop, after TickHoldAutoStep.
-- True in Reforged when OMDGameState:GetIsGameEnded reads true (#103 F2). A failed read is not ended. Each read is in pcall.
function PaceGameEnded()
  if QueueBlockMode() ~= "reforged" then return false end
  local okG, ended = pcall(function()
    local gs = FindFirstOf("OMDGameState")
    if not gs or not gs:IsValid() then return nil end
    return gs:GetIsGameEnded()
  end)
  return okG and ended == true
end
function PaceStep()
  if #PACE_QUEUE == 0 then return end
  -- After the game end the pacer releases nothing (#103 F2). The queue is kept. One line per match.
  if PaceGameEnded() then
    if not PACE.endNoted then
      PACE.endNoted = true
      print(string.format("[Reforged] spawn pace stopped: game ended held=%d", #PACE_QUEUE))
    end
    return
  end
  -- A timed break keeps the queued calls until its countdown ends.
  if ReforgedTimedWait() then return end
  local head = PACE_QUEUE[1]
  local now = os.time()
  -- The round plan's gapMult applies in Reforged only. Manual and Classic keep SPAWN_GAP.
  local mult = (QueueBlockMode() == "reforged") and (REFORGED_GAP_MULT or 1) or 1
  if now - PACE.lastCall < SPAWN_GAP * mult then return end
  local standing = StandingCount()
  if SPAWN_CAP and standing > 0 and standing + head.count > SPAWN_CAP then
    if not head.waitNoted then
      WatchEmit("pace", { what = head.what, count = head.count, wait = true, reason = "cap", standing = standing, cap = SPAWN_CAP })
      head.waitNoted = true
    end
    return
  end
  table.remove(PACE_QUEUE, 1)
  PACE.lastCall = now
  local waited = now - head.since
  PACE.bypass = true
  local okCall, errCall = pcall(head.call)
  PACE.bypass = false
  if not okCall then
    print(string.format("[Reforged] pace call error what=%s err=%s", tostring(head.what), tostring(errCall)))
  end
  WatchEmit("pace", { what = head.what, count = head.count, waited = waited, standing = standing, cap = SPAWN_CAP or WatchNull, gap = SPAWN_GAP })
  print(string.format("[Reforged] spawn pace release what=%s waited=%s standing=%s", head.what, tostring(waited), tostring(standing)))
end
-- spawn-pace (status), spawn-pace clear, spawn-pace gap <0-60>, spawn-pace cap <1-500|off>.
function SpawnPaceCommand(arg1, arg2)
  if arg1 == nil or arg1 == "" then
    print(string.format("[Reforged] spawn-pace gap=%s cap=%s queued=%d active=%s standing=%s", tostring(SPAWN_GAP),
      SPAWN_CAP and tostring(SPAWN_CAP) or "off", #PACE_QUEUE, tostring(QueueBlockActive()), tostring(StandingCount())))
  elseif arg1 == "clear" then
    local n = #PACE_QUEUE
    PACE_QUEUE = {}
    print("[Reforged] spawn-pace clear dropped=" .. tostring(n))
  elseif arg1 == "gap" then
    local v = arg2 ~= nil and arg2:match("^%d+$") and tonumber(arg2) or nil
    if v == nil or v > 60 then print("[Reforged] command rejected: spawn-pace gap needs 0-60 seconds"); return end
    SPAWN_GAP = v
    print("[Reforged] spawn-pace gap=" .. tostring(v))
  elseif arg1 == "cap" then
    if arg2 == "off" then
      SPAWN_CAP = nil
    else
      local v = arg2 ~= nil and arg2:match("^%d+$") and tonumber(arg2) or nil
      if v == nil or v < 1 or v > 500 then print("[Reforged] command rejected: spawn-pace cap needs 1-500 or off"); return end
      SPAWN_CAP = v
    end
    print("[Reforged] spawn-pace cap=" .. (SPAWN_CAP and tostring(SPAWN_CAP) or "off"))
  else
    print("[Reforged] command rejected: use spawn-pace, spawn-pace clear, spawn-pace gap <0-60>, spawn-pace cap <1-500|off>")
  end
end

local doorId = 0
-- Door-call ownership. A new pawn belongs to a door call only when its reflected Spawner is that spawner.
-- When the Spawner read fails or is nil, the pawn belongs only when its X/Y distance from the spawner is under 400 units.
-- One local table, so the main chunk stays under the Lua 5.4 local limit.
local DoorOwn = {}
do
  local DOOR_XY_OWN = 400
  local function SameActor(a, b)
    if a == nil or b == nil then return false end
    if a == b then return true end
    local okA, na = pcall(function() return a:GetFullName() end)
    local okB, nb = pcall(function() return b:GetFullName() end)
    return okA and okB and na ~= nil and tostring(na) == tostring(nb)
  end
  -- Returns owned (boolean) and the test that decided it: "spawner" or "xy".
  function DoorOwn.owned(actor, spawner, spawnerPos)
    local okSp, sp = pcall(function() return actor.Spawner end)
    if okSp and sp ~= nil then return SameActor(sp, spawner), "spawner" end
    local okL, loc = pcall(function() return actor:K2_GetActorLocation() end)
    if okL and loc and spawnerPos then
      local dx, dy = loc.X - spawnerPos.X, loc.Y - spawnerPos.Y
      return math.sqrt(dx * dx + dy * dy) < DOOR_XY_OWN, "xy"
    end
    return false, "xy"
  end
end
DoorOwnsPawn = DoorOwn.owned -- test alias

local function DoorSpawn(doorIndex, row, count)
  if HoardHold(string.format("door %s %s x%s", tostring(doorIndex), tostring(row and row.name), tostring(count)),
    function() DoorSpawn(doorIndex, row, count) end) then return end
  if PaceHold(string.format("door %s %s x%s", tostring(doorIndex), tostring(row and row.name), tostring(count)),
    count, function() DoorSpawn(doorIndex, row, count) end, row ~= nil and row.classicMod == true) then return end
  doorId = doorId + 1
  local id = doorId
  RunOnGameThread("door", function()
    local spawner = FindSpawnerByIndex(doorIndex)
    if not spawner then
      print("[Reforged] door #" .. id .. " rejected: no spawner with indexInLevel " .. tostring(doorIndex))
      return
    end
    -- Spawner gone: true when IsValid fails, raises, or does not return true. The map was left, so the object is stale.
    -- A map change (MAP_EPOCH) counts as gone before any read: the spawner memory can already be freed.
    local epoch = MAP_EPOCH
    local function SpawnerGone()
      if MAP_EPOCH ~= epoch then return true end
      local okV, valid = pcall(function() return spawner:IsValid() end)
      return not (okV and valid == true)
    end
    -- Stock values, read before any write.
    local stock = {}
    for _, name in ipairs({ "MinSpawnCount", "MaxSpawnCount", "MaxAliveCount", "bIsActive" }) do
      local ok, v = pcall(function() return spawner[name] end)
      stock[name] = ok and v or nil
    end
    stock.guid = {}
    for _, k in ipairs(GUID_KEYS) do
      local ok, v = pcall(function() return spawner.SpawnProtodata.Guid[k] end)
      stock.guid[k] = ok and v or nil
    end
    local okKey, keyName = pcall(function() return spawner:GetFullName() end)
    local stockKey = okKey and tostring(keyName) or tostring(doorIndex)
    stock = DoorStockTake(stockKey, stock)
    DoorCallBegin(stockKey)
    local aliveBefore = tonumber(FieldText(spawner, "CurrentAliveCount")) or 0
    print(string.format("[Reforged] door #%d spawn-box bSpawnAtCenter=%s maxSpawnPerRow=%s SpawnDirection=%s override=%s", id,
      FieldText(spawner, "bSpawnAtCenter"), FieldText(spawner, "maxSpawnPerRow"), FieldText(spawner, "SpawnDirection"), tostring(SPAWN_CENTER)))
    if SPAWN_CENTER ~= nil then pcall(function() spawner.bSpawnAtCenter = SPAWN_CENTER end) end
    local okLoc, spawnerLoc = pcall(function() return spawner:K2_GetActorLocation() end)
    print(string.format("[Reforged] door #%d index=%s spawnerLoc=%s spawner=%s stock min=%s max=%s maxAlive=%s active=%s currentAlive=%s proto[%s]",
      id, tostring(doorIndex), okLoc and Vec(spawnerLoc) or "?", ShortName(spawner:GetFullName()), tostring(stock.MinSpawnCount), tostring(stock.MaxSpawnCount),
      tostring(stock.MaxAliveCount), tostring(stock.bIsActive), tostring(aliveBefore), ProtoText(spawner)))

    -- Writes, one pcall each.
    local function write(label, fn)
      local ok, err = pcall(fn)
      print(string.format("[Reforged] door #%d write %s ok=%s%s", id, label, tostring(ok),
        ok and "" or (" err=" .. tostring(err))))
      return ok
    end
    -- The hard gate: MaxAliveCount = CurrentAliveCount + count, read before the first trigger. The timer spawns 1 or 2 pawns per
    -- trigger and stops at MaxAliveCount. The timer does not read MinSpawnCount or MaxSpawnCount,
    -- so these two writes do not limit the count. They stay as before.
    local target = aliveBefore + count
    write("MinSpawnCount", function() spawner.MinSpawnCount = 1 end)
    write("MaxSpawnCount", function() spawner.MaxSpawnCount = 1 end)
    write("MaxAliveCount", function() spawner.MaxAliveCount = target end)
    -- Proto, attempt 1: whole struct from a table.
    print(string.format("[Reforged] door #%d readback after struct write proto[%s] expected A=%s",
      id, ProtoText(spawner), tostring(row.guid.A)))
    -- Proto, attempt 2: component writes into the live struct.
    for _, k in ipairs(GUID_KEYS) do
      write("SpawnProtodata.Guid." .. k, function() spawner.SpawnProtodata.Guid[k] = row.guid[k] end)
    end
    print(string.format("[Reforged] door #%d readback after component writes proto[%s]", id, ProtoText(spawner)))

    local before = {}
    for _, e in ipairs(LiveNonWispAI()) do before[e.full] = true end
    -- BeginSpawning takes a TArray out-parameter, which UE4SS reads back after the call.
    -- The crashes happen in that path, so use the zero-argument timer instead.
    print(string.format("[Reforged] door #%d trigger OnDelayedSpawnTimer (no out-array)", id))
    -- Restores the stock values once. Called at the target, or by the sampler after the last trigger and a margin.
    local finished = false
    local triggersLeft = true
    local function Finish()
      if finished then return end
      finished = true
      -- Spawner gone: do not write into the stale object. Only release the pending call.
      if SpawnerGone() then
        DoorCallEnd(stockKey)
        print(string.format("[Reforged] door #%d restore skipped: spawner gone", id))
        return
      end
      -- Restore after the last pending call on this spawner, from the first stock snapshot.
      if RESTORE_DOOR_STOCK then
        if not DoorCallEnd(stockKey) then
          print(string.format("[Reforged] door #%d restore deferred: %d calls pending on this spawner", id, DOOR_PENDING[stockKey]))
        else
          write("restore MinSpawnCount", function() spawner.MinSpawnCount = stock.MinSpawnCount end)
          write("restore MaxSpawnCount", function() spawner.MaxSpawnCount = stock.MaxSpawnCount end)
          write("restore MaxAliveCount", function() spawner.MaxAliveCount = stock.MaxAliveCount end)
          for _, k in ipairs(GUID_KEYS) do
            write("restore SpawnProtodata.Guid." .. k, function() spawner.SpawnProtodata.Guid[k] = stock.guid[k] end)
          end
          print(string.format("[Reforged] door #%d restore done proto[%s]", id, ProtoText(spawner)))
        end
      else
        DoorCallEnd(stockKey)
        print(string.format("[Reforged] door #%d restore skipped (RESTORE_DOOR_STOCK=false)", id))
      end
    end
    -- Trigger i, one second after trigger i-1. Before each trigger after the first, read CurrentAliveCount. At the target, skip the
    -- rest and restore at once. Otherwise the timer and the sampler decide the restore.
    local function Step(i)
      -- Spawner gone: stop the calls that are left. No alive read, no trigger, no further step.
      if SpawnerGone() then
        triggersLeft = false
        print(string.format("[Reforged] door #%d spawner gone: %d trigger(s) not sent", id, count - i + 1))
        Finish()
        return
      end
      if i > 1 then
        local alive = tonumber(FieldText(spawner, "CurrentAliveCount")) or 0
        if alive >= target then
          triggersLeft = false
          print(string.format("[Reforged] door #%d target reached alive=%d target=%d, %d trigger(s) not sent", id, alive, target, count - i + 1))
          Finish()
          return
        end
      end
      if i > count then triggersLeft = false; return end
      local okT, errT = pcall(function() spawner:OnDelayedSpawnTimer() end)
      print(string.format("[Reforged] door #%d trigger %d/%d ok=%s err=%s", id, i, count,
        tostring(okT), okT and "-" or tostring(errT)))
      After(1000, function() RunOnGameThread("door-step", function() Step(i + 1) end) end)
    end
    Step(1)

    local samples = 0
    local rescued = {}
    -- Loot goblins registered by this call. Each new Kobold of this call registers in the sampler, up to count.
    local goblinAdded = 0
    -- Bearers kept by this call. At most count pawns of the call, like goblinAdded.
    local bearerAdded = 0
    -- Position for the X/Y ownership fallback. Nil when the spawner location read failed.
    local spawnerPos = okLoc and spawnerLoc or nil
    -- The sampler ends only after the last trigger (Step) and a margin of minSamples seconds.
    -- Restoring at a fixed 8 s reverted the spawner while later triggers were still pending.
    local minSamples = math.max(8, count + 2)
    GameLoop(1000, function()
      samples = samples + 1
      -- Spawner gone: end the sampler at once. The pawn scan, waveTrack and loot-goblin parts are skipped.
      if SpawnerGone() then
        print(string.format("[Reforged] door #%d sampler stopped: spawner gone", id))
        triggersLeft = false
        Finish()
        return true
      end
      local okS, errS = pcall(function()
        local fresh = {}
        for _, e in ipairs(LiveNonWispAI()) do
          if not before[e.full] then
            -- Only pawns of this call count, are tracked or are rescued. Other doors' pawns are skipped.
            local owned, owner = DoorOwn.owned(e.actor, spawner, spawnerPos)
            if owned then
              if row.lootGoblin and goblinAdded < count and e.full:find("BP_Kobold") and RegisterGoblinPawn and RegisterGoblinPawn(e) then
                goblinAdded = goblinAdded + 1
              end
              local okL, loc = pcall(function() return e.actor:K2_GetActorLocation() end)
              -- Some pawns (bosses, the first of a call) spawn 400+ units below the door and fall out of the level. Put them back once.
              if okL and loc and okLoc and spawnerLoc and loc.Z < spawnerLoc.Z - 300 and not rescued[e.full] then
                rescued[e.full] = true
                local okR, errR = pcall(function() e.actor:K2_SetActorLocation({ X = spawnerLoc.X, Y = spawnerLoc.Y, Z = spawnerLoc.Z + 60 }, false, {}, true) end)
                print(string.format("[Reforged] door #%d rescue under-floor pawn %s z=%.0f -> spawner z+60 owner=%s ok=%s err=%s", id, ShortName(e.full), loc.Z, owner, tostring(okR), okR and "-" or tostring(errR)))
              end
              -- A boss pawn of a Reforged boss round is kept for the coin reward on death.
              local bossK = row.bossK
              if bossK == nil and ReforgedIsBossName(row.name) then bossK = math.max(1, math.floor(REFORGED.round / ReforgedBossEvery())) end
              if bossK ~= nil then ReforgedBossRegister(e.actor, e.full, row.name, bossK) end
              -- A banner bearer is kept for the reinforcement calls of its door. Only in Reforged, or in Classic
              -- when the call comes from a Classic modifier (row.classicCfg is its reinforce block).
              if row.bearer == true and bearerAdded < count then
                local okBR, addedBR = pcall(ReforgedBearerRegister, e.actor, e.full, row.name, doorIndex, row.classicCfg)
                if okBR and addedBR == true then bearerAdded = bearerAdded + 1 end
              end
              -- A door Moneybags is kept for the 500-coin pickup it does not drop. Only when its marker reads 0.
              -- A Classic modifier's Moneybags is kept in Classic.
              if row.name == "OgreMoneybags" then pcall(ReforgedMoneybagsRegister, e.actor, e.full, row.classicMod == true) end
              local okPN, pn = pcall(function() return e.actor:GetProtoName():ToString() end)
              local okD, dist = pcall(function() return DistanceTo(e.actor, spawnerLoc) end)
              fresh[#fresh + 1] = string.format("%s proto=%s dDoor=%s loc=%s",
                ShortName(e.full), okPN and tostring(pn) or "?",
                okD and string.format("%.0f", dist) or "?",
                okL and Vec(loc) or "?")
            end
          end
        end
        print(string.format("[Reforged] door #%d +%ds currentAlive=%s new=%d [%s]",
          id, samples, FieldText(spawner, "CurrentAliveCount"), #fresh,
          #fresh > 0 and table.concat(fresh, "; ", 1, math.min(#fresh, 6)) or "none"))
      end)
      if not okS then
        print(string.format("[Reforged] door #%d +%ds sampler error: %s", id, samples, Describe(errS)))
      end
      if samples < minSamples or triggersLeft then return false end
      if waveTrack.active then
        -- Track only pawns whose proto matches the requested type, so stock-wave pawns are not counted.
        for _, e in ipairs(LiveNonWispAI()) do
          if not before[e.full] and DoorOwn.owned(e.actor, spawner, spawnerPos) then
            local okP, pn = pcall(function() return e.actor:GetProtoName():ToString() end)
            if okP and tostring(pn) == row.name then
              waveTrack.pawns[e.full] = e.actor
              waveTrack.lastSpawn = os.time()
            end
          end
        end
      end
      if row.lootGoblin and goblinAdded < count then
        print(string.format("[Reforged] loot-goblin: only %d of %d new Kobold pawns found door #%d", goblinAdded, count, id))
      end
      Finish()
      return true
    end)
  end)
end

-- Go Breaks. OnslaughtGoBreak is the coordinator call behind a player "go"
-- break. UOMDDifficultyManager.EndlessIterationNoGoBreaks is the Endless
-- setting that suppresses breaks. Both are read here; effect is measured via
-- the OnslaughtGoBreak call counter and the spawn/wave logs.
local goBreakCalls, goBreakHooked = 0, false
local function HookGoBreaks()
  if goBreakHooked then return end
  -- Count and name only. Every crash today followed `testing on`. Symbolized UE4SS frames show Lua touching a game object that may be gone. Cause inferred.
  local ok, err = SafeRegisterHook("/Script/OMD.OMDOnslaughtCoordinator:OnslaughtGoBreak", function()
    if not DiagOn() then return end
    goBreakCalls = goBreakCalls + 1
    print(string.format("[Reforged] OnslaughtGoBreak call #%d", goBreakCalls))
  end)
  goBreakHooked = ok
  print("[Reforged] OnslaughtGoBreak hook registered=" .. tostring(ok) .. " " .. tostring(err))
  -- Player-facing break state (the G "Unleash the Horde" input).
  for _, fn in ipairs({ "SetGoBreakActive", "SetGoBreakReady" }) do
    local okG, errG = SafeRegisterHook("/Script/OMD.OMDGameState:" .. fn, function()
      if DiagOn() then print("[Reforged] GameState " .. fn .. " call") end
    end)
    print("[Reforged] GameState " .. fn .. " hook registered=" .. tostring(okG) .. " " .. tostring(errG))
  end
end

-- Keep the start-endless-test runner independent from menu widget internals.
-- The runner enters Endless through the visible game UI. This monitor only
-- reports when the match coordinator exists, then arms the G-call hook.
local autoTestMapReady = false
local BreaksOff
DIAG[#DIAG + 1] = HookGoBreaks

-- Wave events. PawnHasDied_impl (0x140fb00e0) takes the coordinator and the dead
-- pawn. Candidate break names are registered only to learn which exist; a
-- registered=false line means the name is wrong.
local deathCalls = 0
local function HookWaveEvents()
  local okD, errD = SafeRegisterHook("/Script/OMD.OMDOnslaughtCoordinator:PawnHasDied", function(self, pawn)
    if not DiagOn() then return end
    deathCalls = deathCalls + 1
    print(string.format("[Reforged] pawn died #%d", deathCalls))
  end)
  print("[Reforged] PawnHasDied hook registered=" .. tostring(okD) .. " " .. tostring(errD))
  for _, fn in ipairs({ "OnslaughtWaveBreak" }) do
    local okB, errB = SafeRegisterHook("/Script/OMD.OMDOnslaughtCoordinator:" .. fn, function()
      print("[Reforged] break event " .. fn)
    end)
    print("[Reforged] candidate " .. fn .. " registered=" .. tostring(okB) .. " " .. tostring(errB))
  end
end
DIAG[#DIAG + 1] = HookWaveEvents
local lastFeignAttempt = -1
local function SamplePlayerAggro(pawn, label)
  local total, targeting = 0, 0
  local ok, controllers = pcall(FindAllOf, "OMDAIController")
  if ok and controllers then
    for _, controller in ipairs(controllers) do
      if controller and controller:IsValid() then
        total = total + 1
        local gotTarget, target = pcall(function() return controller:GetEnemyActor() end)
        if gotTarget and target == pawn then targeting = targeting + 1 end
      end
    end
  end
  print(string.format("[Reforged] feign-agro sample %s aiControllers=%d targetingPlayer=%d",
    label, total, targeting))
end

-- Random wave: each pawn gets a random type and a random door. One door call
-- per pawn, 10 seconds apart, so door calls never overlap on the same spawner.
local WAVE_TYPES = { "OrcMedium", "OrcLight", "Kobold", "OrcHeavy" }
local function RandomWave(count, spacingSeconds)
  local spacing = math.max(10, tonumber(spacingSeconds) or 10)
  local doors = GetSpawnerIndexes()
  if #doors == 0 then
    print("[Reforged] wave rejected: no live door spawners")
    return
  end
  WaveBegin(string.format("random x%d", count), math.max(0, (count - 1) * spacing) + 8)
  for i = 1, count do
    local row = PROTO_BY_NAME[WAVE_TYPES[math.random(#WAVE_TYPES)]]
    local door = doors[math.random(#doors)]
    After((i - 1) * spacing * 1000, function() DoorSpawn(door, row, 1) end)
  end
  print(string.format("[Reforged] wave scheduled count=%d spacing=%ds", count, spacing))
end

-- Reforged wave source. Each Reforged round is a plan made
-- from the round number, the seed and REFORGED_WAVES. ReforgedStep replays the plan as DoorSpawn calls at the build-phase start.
-- The tables and functions are globals: the main chunk is near the 200-local limit.
REFORGED_WAVES = {
  capStart = 20, capGrowthPercent = 2, sizeBase = 20, sizeStep = 4, promoteStep = 2, promoteMax = 50,
  bossEvery = 10, squadMin = 2, squadMax = 6, ramp = 5, escortMin = 2, escortMax = 6,
  -- Map bias: a proto whose family is the map's own family is weighted mapBias inside its tier. 1 = no bias.
  mapBias = 2,
  tiers = {
    { unlock = 1, protos = { "OrcLight", "Kobold", "LizardmanLight", "FireFiendLight", "ElementalFireling", "ElementalEarthling" } },
    { unlock = 3, max = 40, protos = { "OrcMedium", "OrcArcher", "KoboldTNT", "GnollAssassin", "LizardmanRanger", "FireFiendRunner", "FireFiendMedium", "CyclopsMedium" } },
    { unlock = 6, max = 30, protos = { "OrcHeavy", "OrcArcherTNT", "Ogre", "Troll", "LizardmanHeavy", "CyclopsHeavy", "CyclopsMage", "GnollGrenadier", "FireFiendHeavy", "ElementalFire", "ElementalEarth", "WraithHealer" } },
    { unlock = 10, max = 15, protos = { "OgreArmored", "TrollMountain", "CyclopsShaman", "CyclopsMesmerizer", "FireFiendMage", "ElementalFireLord", "ElementalEarthLord", "LizardmanAssassin" } },
  },
  bosses = { "OrcBoss", "KoboldKing", "OgreBasher", "WraithBoss" },
  -- The escort family of each boss. A boss round adds one squad of escortMin to escortMax pawns from this list.
  escorts = { OrcBoss = { "OrcHeavy", "OrcMedium" }, KoboldKing = { "KoboldTNT", "Kobold" }, OgreBasher = { "Ogre", "OgreArmored" }, WraithBoss = { "WraithHealer" } },
}
-- Map families. Source: the Endless map families (level column, families at share_pct 5% or more).
-- The 5% cut-off is a fixed value. A family listed here is the map's own family. Read by ReforgedPlan through REFORGED.level.
-- A level that is not listed has no own families. Generated once from the TSV; regenerate it with the same cut-off.
REFORGED_MAP_FAMILIES = {
  Scenario_01 = { "Orc" },
  Scenario_02 = { "Orc" },
  Scenario_03 = { "Orc", "Kobold", "FireFiend" },
  Scenario_04 = { "Orc", "Kobold" },
  Scenario_05 = { "Orc", "Kobold" },
  Scenario_07 = { "Orc", "Kobold", "Ogre", "Elemental" },
  Scenario_Other_02 = { "Orc", "Kobold" },
  Scenario_08 = { "Orc", "Kobold" },
  Scenario_10 = { "Orc", "Kobold", "Elemental" },
  Scenario_11 = { "Orc", "Kobold" },
  Scenario_13 = { "Orc", "FireFiend" },
  Scenario_14 = { "Orc", "FireFiend", "Kobold" },
  Scenario_Other_03 = { "Orc", "FireFiend", "Kobold", "Elemental" },
  Scenario_16 = { "Orc" },
  Scenario_17 = { "FireFiend", "Orc", "Kobold" },
  ScenarioDLC_01 = { "Orc", "Hellbat" },
  ScenarioDLC_02 = { "Orc", "Hellbat", "FireFiend" },
  ScenarioDLC_04 = { "Orc", "Hellbat", "FireFiend", "Kobold" },
  ScenarioDLC_05 = { "Orc", "FireFiend", "Hellbat" },
  Scenario_Ice_01 = { "Cyclops", "Hellbat", "Orc", "Kobold" },
  Scenario_Ice_02 = { "Cyclops", "Orc", "Hellbat", "Kobold" },
  Scenario_Ice_03 = { "Cyclops", "Orc" },
  Scenario_Sand_04 = { "Lizardman", "Orc", "Kobold" },
  Scenario_Sand_05 = { "Lizardman", "Hellbat", "Orc" },
  Scenario_Sand_01 = { "Lizardman", "Orc", "Kobold", "Elemental" },
  Scenario_Sand_02 = { "Lizardman" },
  -- War Scenario levels (#101): docs/war-scenario-map-families-2026-10-20.tsv, same 5% cut-off.
  Scenario_06 = { "Orc", "Kobold" },
  Scenario_09 = { "Orc", "Kobold", "Elemental" },
  Scenario_15 = { "FireFiend", "Orc" },
  Scenario_12 = { "Orc", "Kobold" },
  Scenario_18 = { "Orc", "FireFiend", "Ogre" },
  ScenarioDLC_03 = { "Hellbat", "Orc", "FireFiend" },
  Scenario_Sand_03 = { "Lizardman", "Orc", "FireFiend", "Hellbat" },
}
-- War Scenario map bosses (#101 M5). Level -> the coordinator action that makes the level script spawn its boss
-- (DoOnslaughtAction). Source: OnslaughtAction calls at authored wave 5 (docs/war-scenario-endless-research-2026-10-20.md).
REFORGED_MAP_BOSS = { Scenario_06 = "SpawnCragg", Scenario_09 = "SpawnGhorbash", Scenario_12 = "SpawnZelzadore", Scenario_15 = "SpawnMongrifel" }
-- Boss rounds on a REFORGED_MAP_BOSS level: every 5 rounds (the stock cadence, user 2026-10-20). Other levels use bossEvery.
REFORGED_MAP_BOSS_EVERY = 5
-- Wave size factor per level: Classic mean wave / stock-map median (64.5). From `endless_extra_maps.py lua-size`.
-- It multiplies ReforgedSize and ReforgedCap on that level. A level not listed has factor 1.
REFORGED_MAP_SIZE = {
  Scenario_06 = 4.18,
  Scenario_09 = 4.14,
  Scenario_15 = 3.64,
  Scenario_12 = 5.43,
  Scenario_18 = 3.85,
  ScenarioDLC_03 = 3.87,
  Scenario_Sand_03 = 4.28,
}
-- Catalog proto -> family. Every PROTOS name has one. LootGoblin is a Kobold with a flag (see above).
REFORGED_PROTO_FAMILY = {
  -- Orc: OrcBoss, OrcLight, OrcMedium, OrcHeavy, OrcArcher, OrcArcherTNT
  OrcBoss = "Orc", OrcLight = "Orc", OrcMedium = "Orc", OrcHeavy = "Orc", OrcArcher = "Orc", OrcArcherTNT = "Orc",
  -- Kobold: KoboldKing, Kobold, KoboldTNT, LootGoblin
  KoboldKing = "Kobold", Kobold = "Kobold", KoboldTNT = "Kobold", LootGoblin = "Kobold",
  -- Ogre: OgreBasher, Ogre, OgreArmored, OgreMoneybags
  OgreBasher = "Ogre", Ogre = "Ogre", OgreArmored = "Ogre", OgreMoneybags = "Ogre",
  -- Troll: Troll, TrollMountain
  Troll = "Troll", TrollMountain = "Troll",
  -- Gnoll: GnollAssassin, GnollGrenadier
  GnollAssassin = "Gnoll", GnollGrenadier = "Gnoll",
  -- Lizardman: LizardmanLight, LizardmanHeavy, LizardmanRanger, LizardmanAssassin
  LizardmanLight = "Lizardman", LizardmanHeavy = "Lizardman", LizardmanRanger = "Lizardman", LizardmanAssassin = "Lizardman",
  -- Cyclops: CyclopsMedium, CyclopsHeavy, CyclopsMage, CyclopsMesmerizer, CyclopsShaman
  CyclopsMedium = "Cyclops", CyclopsHeavy = "Cyclops", CyclopsMage = "Cyclops", CyclopsMesmerizer = "Cyclops", CyclopsShaman = "Cyclops",
  -- FireFiend: FireFiendLight, FireFiendMedium, FireFiendHeavy, FireFiendRunner, FireFiendMage, FireFiendOverlord
  FireFiendLight = "FireFiend", FireFiendMedium = "FireFiend", FireFiendHeavy = "FireFiend", FireFiendRunner = "FireFiend", FireFiendMage = "FireFiend", FireFiendOverlord = "FireFiend",
  -- Elemental: ElementalEarthling, ElementalEarth, ElementalEarthLord, ElementalFireling, ElementalFire, ElementalFireLord
  ElementalEarthling = "Elemental", ElementalEarth = "Elemental", ElementalEarthLord = "Elemental", ElementalFireling = "Elemental", ElementalFire = "Elemental", ElementalFireLord = "Elemental",
  -- Wraith: WraithBoss, WraithHealer
  WraithBoss = "Wraith", WraithHealer = "Wraith",
  -- Hellbat: HellbatFire, HellbatBaby, HellbatIce, HellbatLigtning, HellbatBile, HellbatArcane, HellbatBoss
  HellbatFire = "Hellbat", HellbatBaby = "Hellbat", HellbatIce = "Hellbat", HellbatLigtning = "Hellbat", HellbatBile = "Hellbat", HellbatArcane = "Hellbat", HellbatBoss = "Hellbat",
}
-- Boss reward: coins paid once when a director boss pawn dies. Amount = round(REFORGED_BOSS_COINS * (1 + 0.05 * (k - 1))), k = the boss round index.
REFORGED_BOSS_COINS = 500
-- Boss pawns of the current map: full name -> { actor, k, proto }. Filled by the door sampler in Reforged. Cleared at map ready.
REFORGED_BOSSES_LIVE = {}
-- Banner bearers of the current map: full name -> { actor, proto, door, round, calls, last, cfg }. Cleared at map ready.
REFORGED_BEARERS = {}
-- Reinforcement settings of the current round plan (plan.reinforce). nil when the round has no reinforcement.
REFORGED_REINFORCE = nil
REFORGED_BUDGET = 120 -- the cap ceiling (activeEnemyBudget). nil = no ceiling.
REFORGED_SIZE_SCALE = 1.0 -- waveSizeScale
REFORGED_PROMOTE_FIXED = nil -- promotePercent when it is a number. nil = auto (promoteStep per round).
REFORGED_PLAN_HOOK = nil -- optional function(plan, ctx) that returns a plan (wave modifiers). Set by the modifier loader below.
-- Wave modifiers. lib = modifiers.lua once it loads; loadErr = its load error. on/chance/minRound are the settings rows.
-- classic: the modifiersInClassic row, "on" or "off". Off (default) keeps Classic unchanged.
REFORGED_MOD = { lib = nil, loadErr = nil, on = true, chance = 20, minRound = 3, last = nil, forced = nil, preview = false, classic = "off" }
-- Stock replay wave source. lib = stock_waves.lua once it loads; loadErr = its load error. source = the waveSource row
-- ("generator" or "stock"). fellBack = round numbers that already printed the fallback line.
REFORGED_STOCK = { lib = nil, loadErr = nil, source = "generator", fellBack = {} }
-- Modifier banner. on: the modifierBanner row (default on). pending: the rolled id of the next Reforged combat round, set by the plan hook.
HUD_BANNER = { on = true, pending = nil }
REFORGED_GAP_MULT = 1 -- PaceStep gap multiplier from the round plan (gapMult). 1 = SPAWN_GAP. Set per built round.
REFORGED_WARNED = {}
-- ready is true only after MapReadyFor has set the seed for the current map. ReforgedStep builds no round until then.
REFORGED = { round = 0, lastBuild = nil, seed = 0, last = nil, inBuild = nil, doorStart = 0, ready = false }

-- Wave size factor of the current level (REFORGED_MAP_SIZE). 1 when the level is not listed.
function ReforgedSizeFactor()
  return REFORGED_MAP_SIZE[REFORGED.level] or 1
end
-- Boss every N rounds: REFORGED_MAP_BOSS_EVERY on a map-boss level, else REFORGED_WAVES.bossEvery.
function ReforgedBossEvery()
  if REFORGED_MAP_BOSS[REFORGED.level] ~= nil then return REFORGED_MAP_BOSS_EVERY end
  return REFORGED_WAVES.bossEvery
end
-- True when round r is a boss round of the current level.
function ReforgedIsBossRound(r)
  local e = ReforgedBossEvery()
  return e ~= nil and e > 0 and r % e == 0
end
-- Cap for round r (from 1): capStart grown by capGrowthPercent per round, times the level size factor, at most REFORGED_BUDGET.
function ReforgedCap(r)
  local raw = math.floor(REFORGED_WAVES.capStart * (1 + REFORGED_WAVES.capGrowthPercent / 100) ^ (r - 1) * ReforgedSizeFactor() + 0.5)
  if REFORGED_BUDGET ~= nil and raw > REFORGED_BUDGET then return REFORGED_BUDGET end
  return raw
end
-- Pawns in round r: sizeBase, plus sizeStep per round, times REFORGED_SIZE_SCALE and the level size factor. At least 1.
function ReforgedSize(r)
  local w = REFORGED_WAVES
  return math.max(1, math.floor((w.sizeBase + w.sizeStep * (r - 1)) * REFORGED_SIZE_SCALE * ReforgedSizeFactor() + 0.5))
end
-- Promote percent: the promotePercent setting when it is a number, else promoteStep per round, at most promoteMax.
function ReforgedPromote(r)
  if type(REFORGED_PROMOTE_FIXED) == "number" then return REFORGED_PROMOTE_FIXED end
  return math.min(REFORGED_WAVES.promoteMax, REFORGED_WAVES.promoteStep * (r - 1))
end
-- Stock replay. ReforgedStockIterIn is the iters rule of scripts/stock_waves.py (iter_in): "all", "N+" or a comma list.
function ReforgedStockIterIn(iters, I)
  local value = string.lower(tostring(iters or ""))
  value = value:match("^%s*(.-)%s*$")
  if value == "all" then return true end
  if value:sub(-1) == "+" then
    local n = tonumber(value:sub(1, -2))
    return n ~= nil and I >= n
  end
  for part in string.gmatch(value, "[^,]+") do
    if tonumber(part) == I then return true end
  end
  return false
end
-- The stock rows of REFORGED round r on level. I = (r - 1) div M, w = r - I * M. Rows of stock round w whose iters include I.
-- Count: the table count at I = 0. At I >= 1: count + step * endless_add, with s = min(I, floor(25 / M + 0.5)) and step = s - 1
-- when difficulty is 4 (else s). Rows with count 0 and rows with a proto not in the catalog are dropped.
-- Returns rows = { {spawner, proto, count}, ... }, w, I. Or nil, reason: not-loaded, no-map, no-rows.
function ReforgedStockRound(level, r)
  local lib = REFORGED_STOCK.lib
  if lib == nil then return nil, "not-loaded" end
  local lv = type(level) == "string" and lib.levels[level] or nil
  if lv == nil or (tonumber(lv.M) or 0) < 1 then return nil, "no-map" end
  local M = lv.M
  r = math.max(1, math.floor(tonumber(r) or 1))
  local I = (r - 1) // M
  local w = r - I * M
  local rows = {}
  local src = lv.rounds[w]
  if src ~= nil then
    local s = math.min(I, math.floor(25 / M + 0.5))
    for _, row in ipairs(src) do
      local spawner, proto, count, add, dif, iters = row[1], row[2], row[3], row[4], row[5], row[6]
      if ReforgedStockIterIn(iters, I) then
        local n = count
        if I >= 1 then
          local step = s
          if dif == 4 then step = math.max(0, s - 1) end
          n = count + step * add
        end
        if n > 0 and PROTO_BY_NAME[proto] ~= nil then
          rows[#rows + 1] = { spawner = spawner, proto = proto, count = n }
        end
      end
    end
  end
  if #rows == 0 then return nil, "no-rows" end
  return rows, w, I
end
-- Seeded generator on Lua 5.4 integers (64-bit LCG). Returns next(n), an integer 1..n. The same seed gives the same sequence.
function ReforgedRng(seed)
  local state = (math.tointeger(math.floor(tonumber(seed) or 0)) or 0) ~ 0x2545F4914F6CDD1D
  return function(n)
    state = state * 6364136223846793005 + 1442695040888963407
    n = math.floor(tonumber(n) or 1)
    if n < 1 then return 1 end
    return ((state >> 33) % n) + 1
  end
end
-- Catalog names from a list. A name that is not in PROTO_BY_NAME is skipped and logged once.
function ReforgedNames(list, where)
  local out = {}
  for _, name in ipairs(list or {}) do
    if PROTO_BY_NAME[name] then
      out[#out + 1] = name
    elseif not REFORGED_WARNED[name] then
      REFORGED_WARNED[name] = true
      print("[Reforged] reforged wave source: skipped " .. where .. " proto not in catalog: " .. tostring(name))
    end
  end
  return out
end
-- The round plan: { round, size, cap, promote, entries = { {proto, count, promote}, ... } }. The same r and seed give the same plan.
-- Tier 1 gets the share the other unlocked tiers do not take. Tier k > 1 gets min(max, ramp * (r - unlock + 1)) percent.
-- A boss round starts with one boss. The rest is squads of squadMin to squadMax pawns of one proto, until size is reached.
function ReforgedPlan(r, seed)
  local w = REFORGED_WAVES
  r = math.max(1, math.floor(tonumber(r) or 1))
  seed = math.floor(tonumber(seed) or 0)
  local rng = ReforgedRng(seed * 1000003 + r)
  local promote = ReforgedPromote(r)
  local cap = ReforgedCap(r)
  -- Stock source: the stock rows of this round. nil = the generator plans the round (a fallback prints once per round number).
  local stockRows, stockW, stockI = nil, nil, nil
  if REFORGED_STOCK.source == "stock" then
    local rowsS, a, b = ReforgedStockRound(REFORGED.level, r)
    if rowsS ~= nil then
      stockRows, stockW, stockI = rowsS, a, b
    elseif REFORGED_STOCK.fellBack[r] ~= true then
      REFORGED_STOCK.fellBack[r] = true
      print(string.format("[Reforged] stock source fallback round=%s why=%s", tostring(r), tostring(a)))
    end
  end
  local size
  if stockRows ~= nil then
    -- The stock total, times waveSizeScale. The Reforged size curve is not used for this source.
    local total = 0
    for _, row in ipairs(stockRows) do total = total + row.count end
    size = math.max(1, math.floor(total * REFORGED_SIZE_SCALE + 0.5))
  else
    size = ReforgedSize(r)
  end
  local tiers, others = {}, 0
  for k, t in ipairs(w.tiers) do
    local protos = ReforgedNames(t.protos, "tier " .. k)
    if r >= t.unlock and #protos > 0 then
      local share = 0
      if k > 1 then
        share = math.min(t.max or 100, w.ramp * (r - t.unlock + 1))
        others = others + share
      end
      tiers[#tiers + 1] = { k = k, protos = protos, share = share }
    end
  end
  for _, tr in ipairs(tiers) do
    if tr.k == 1 then tr.share = math.max(0, 100 - others) end
  end
  local function pickTier()
    local total = 0
    for _, tr in ipairs(tiers) do total = total + tr.share end
    if total <= 0 then return tiers[1] end
    local roll, acc = rng(total), 0
    for _, tr in ipairs(tiers) do
      acc = acc + tr.share
      if roll <= acc then return tr end
    end
    return tiers[#tiers]
  end
  -- Map bias: the own families of the current map (REFORGED.level). An unknown map has none, so every weight is 1.
  local own = {}
  local ownList = type(REFORGED) == "table" and type(REFORGED.level) == "string" and REFORGED_MAP_FAMILIES[REFORGED.level] or nil
  for _, f in ipairs(ownList or {}) do own[f] = true end
  local bias = math.max(0, tonumber(w.mapBias) or 1)
  -- One seeded roll for each pick. With no bias every weight is 1, so the roll is the same as a uniform pick.
  local function pickProto(tr)
    local weights, total = {}, 0
    for i, name in ipairs(tr.protos) do
      local fam = REFORGED_PROTO_FAMILY[name]
      weights[i] = (fam ~= nil and own[fam] == true) and bias or 1
      total = total + weights[i]
    end
    if total <= 0 then return tr.protos[rng(#tr.protos)] end
    local roll, acc = rng(total), 0
    for i, name in ipairs(tr.protos) do
      acc = acc + weights[i]
      if roll <= acc then return name end
    end
    return tr.protos[#tr.protos]
  end
  local entries, remaining = {}, size
  -- Map boss (#101 M5): a War Scenario level with REFORGED_MAP_BOSS. Its boss is the level's own DoOnslaughtAction, not a catalog entry.
  local mapBossAction = nil
  if ReforgedIsBossRound(r) then
    local bosses = ReforgedNames(w.bosses, "boss")
    mapBossAction = REFORGED_MAP_BOSS[REFORGED.level]
    if mapBossAction ~= nil or #bosses > 0 then
      local boss = nil
      if mapBossAction == nil then
        boss = bosses[rng(#bosses)]
        entries[1] = { proto = boss, count = 1, promote = promote, boss = true }
      end
      remaining = remaining - 1
      -- Escort: one squad of the boss family. With no valid family, a T2 or T3 proto of this round.
      local escortMin = math.max(1, w.escortMin or 2)
      local escortMax = math.max(escortMin, w.escortMax or 6)
      local family = {}
      if boss ~= nil then family = ReforgedNames((w.escorts or {})[boss] or {}, "escort " .. boss) end
      local escort = nil
      if #family > 0 then
        escort = family[rng(#family)]
      else
        local pool = {}
        for _, tr in ipairs(tiers) do
          if tr.k == 2 or tr.k == 3 then
            for _, n in ipairs(tr.protos) do pool[#pool + 1] = n end
          end
        end
        if #pool == 0 then
          local tr = pickTier()
          if tr ~= nil then pool = tr.protos end
        end
        if #pool > 0 then escort = pool[rng(#pool)] end
      end
      if escort ~= nil and remaining > 0 then
        local count = math.max(1, math.min(escortMin + rng(escortMax - escortMin + 1) - 1, remaining))
        entries[2] = { proto = escort, count = count, promote = promote }
        remaining = remaining - count
      end
    end
  end
  -- Stock replay: the stock rows scaled to the rows left after the boss entries. Largest remainder: each row gets
  -- floor(count * remaining / T). The rest goes one each to the largest fractions, a tie to the earlier row. Adjacent rows
  -- with the same spawner and proto merge. The generator squad loop does not run for this source.
  if stockRows ~= nil then
    local total = 0
    for _, row in ipairs(stockRows) do total = total + row.count end
    local base, frac, sum = {}, {}, 0
    for i, row in ipairs(stockRows) do
      local num = row.count * remaining
      base[i] = num // total
      frac[i] = num % total
      sum = sum + base[i]
    end
    local left = remaining - sum
    while left > 0 do
      local best = nil
      for i = 1, #stockRows do
        if frac[i] >= 0 and (best == nil or frac[i] > frac[best]) then best = i end
      end
      if best == nil then break end
      base[best] = base[best] + 1
      frac[best] = -1
      left = left - 1
    end
    local merged = {}
    for i, row in ipairs(stockRows) do
      local n = base[i]
      if n > 0 then
        local last = merged[#merged]
        if last ~= nil and last.door == row.spawner and last.proto == row.proto then
          last.count = last.count + n
        else
          merged[#merged + 1] = { proto = row.proto, count = n, promote = promote, door = row.spawner }
        end
      end
    end
    for _, m in ipairs(merged) do entries[#entries + 1] = m end
    remaining = 0
    print(string.format("[Reforged] reforged round=%d source=stock stockRound=%d stockIter=%d rows=%d size=%d", r, stockW, stockI, #merged, size))
  end
  local squadMin = math.max(1, w.squadMin)
  local squadMax = math.max(squadMin, w.squadMax)
  while remaining > 0 and stockRows == nil do
    local tr = pickTier()
    if tr == nil then
      print("[Reforged] reforged round=" .. r .. " no tier has a catalog proto, plan is short")
      break
    end
    local proto = pickProto(tr)
    local squad = squadMin + rng(squadMax - squadMin + 1) - 1
    local count = math.max(1, math.min(squad, remaining))
    entries[#entries + 1] = { proto = proto, count = count, promote = promote }
    remaining = remaining - count
  end
  local plan = { round = r, size = size, cap = cap, promote = promote, entries = entries, mapBoss = mapBossAction }
  if stockRows ~= nil then
    plan.source, plan.stockRound, plan.stockIter = "stock", stockW, stockI
  elseif REFORGED_STOCK.source == "stock" then
    plan.source = "generator" -- the fallback (above)
  end
  if type(REFORGED_PLAN_HOOK) == "function" then
    -- The hook gets a copy, so a hook that fails part way cannot change the plan.
    local copy = { round = r, size = size, cap = cap, promote = promote, entries = {}, source = plan.source, stockRound = plan.stockRound, stockIter = plan.stockIter, mapBoss = plan.mapBoss }
    for i, e in ipairs(entries) do copy.entries[i] = { proto = e.proto, count = e.count, promote = e.promote, boss = e.boss, door = e.door } end
    local okH, res = pcall(REFORGED_PLAN_HOOK, copy, { round = r, seed = seed, cap = cap, mode = "reforged" })
    if okH and type(res) == "table" then
      -- A returned plan with no source keeps the source of this plan.
      if res.source == nil then res.source, res.stockRound, res.stockIter = plan.source, plan.stockRound, plan.stockIter end
      -- The map boss is kept too when the hook returns a plan without it.
      if res.mapBoss == nil then res.mapBoss = plan.mapBoss end
      plan = res
    else
      print("[Reforged] reforged plan hook " .. (okH and "returned no table" or ("failed: " .. tostring(res))) .. ", plan kept")
    end
  end
  return plan
end
-- Promotion table: proto -> promoted proto. The 15 rows of the native CDO PromotionList.
-- A proto with no row never promotes.
REFORGED_PROMOTE = {
  OrcLight = "OrcMedium", OrcMedium = "OrcHeavy", OrcHeavy = "Ogre", Ogre = "OgreArmored",
  FireFiendLight = "FireFiendMedium", FireFiendMedium = "FireFiendHeavy",
  ElementalEarthling = "ElementalEarth", ElementalEarth = "ElementalEarthLord",
  ElementalFireling = "ElementalFire", ElementalFire = "ElementalFireLord",
  Troll = "TrollMountain", OrcArcher = "OrcArcherTNT", OrcArcherTNT = "CyclopsMage",
  CyclopsMedium = "CyclopsHeavy", LizardmanLight = "LizardmanHeavy",
}
-- Expands plan entries the native way (Q2). For each entry, f = promote / 100 (clamped 0..1).
-- promoted = floor(count * f). The entry keeps count - promoted. The promoted count repeats with REFORGED_PROMOTE[proto], until
-- promoted is 0 or the proto has no row. A promoted proto not in PROTO_BY_NAME is not used: its count stays the base proto.
-- Equal protos merge within one original entry, in first-seen order. The total count is kept. Returns a new list of
-- { proto, count, promote, door }. The input is not changed.
function ReforgedExpandPromote(entries)
  local out = {}
  for _, e in ipairs(entries or {}) do
    local f = math.max(0, math.min(100, tonumber(e.promote) or 0)) / 100
    local mine, index = {}, {}
    local function add(proto, n)
      if n <= 0 then return end
      if index[proto] then
        mine[index[proto]].count = mine[index[proto]].count + n
      else
        mine[#mine + 1] = { proto = proto, count = n }
        index[proto] = #mine
      end
    end
    local cur, n = e.proto, tonumber(e.count) or 0
    while true do
      local promoted = math.floor(n * f)
      local nxt = REFORGED_PROMOTE[cur]
      if promoted > 0 and nxt ~= nil and PROTO_BY_NAME[nxt] ~= nil then
        add(cur, n - promoted)
        cur, n = nxt, promoted
      else
        add(cur, n)
        break
      end
    end
    for _, m in ipairs(mine) do
      out[#out + 1] = { proto = m.proto, count = m.count, promote = e.promote, door = e.door, boss = e.boss, bearer = e.bearer }
    end
  end
  return out
end
-- Door preview. The OMDDoor of each door the round plan uses gets bIsExpectingMobs = true (minimap Door_NextWave /
-- Door_EnemiesComing); the other doors get false. Source: the wave-preview research, option E. Writes run in Reforged only.
-- The native round end writes false on every door, so the marks are written again at each change into build phase.
-- Switch: REFORGED_PREVIEW (developer command `preview on|off|status`). Writes stay in pcall.
REFORGED_PREVIEW = true
-- Nearest door accepted for a spawner with no StartingDoor (3D units).
REFORGED_PREVIEW_NEAR = 3000
-- Door classes the preview reads. Doors merge by GetFullName, so one door under two names counts once.
REFORGED_PREVIEW_DOOR_CLASSES = { "OMDDoor", "BP_Door_Exterior_Base_C", "BP_Door_Exterior_2W_C", "BP_Door_Exterior_3W_C",
  "BP_Door_Exterior_3W_SAND_C", "BP_Door_Forcefield_C" }
-- Door list for the preview, built once per map (REFORGED.previewDoorList). Valid actors only. Prints one found line per map.
function ReforgedPreviewDoorList()
  if REFORGED.previewDoorList ~= nil then return REFORGED.previewDoorList end
  local list, seen, parts = {}, {}, {}
  for _, cls in ipairs(REFORGED_PREVIEW_DOOR_CLASSES) do
    local okF, found = pcall(FindAllOf, cls)
    local count = 0
    if okF and found ~= nil then
      for _, d in ipairs(found) do
        local okV, valid = pcall(function() return d:IsValid() end)
        if okV and valid == true then
          count = count + 1
          local okN, key = pcall(function() return d:GetFullName() end)
          if not okN or key == nil then key = tostring(d) end
          if seen[key] == nil then
            seen[key] = true
            list[#list + 1] = d
          end
        end
      end
    end
    if count > 0 then parts[#parts + 1] = cls .. ":" .. count end
  end
  REFORGED.previewDoorList = list
  ReforgedPreviewWarnOnce(string.format("preview doors found n=%d classes=%s", #list, #parts > 0 and table.concat(parts, ",") or "-"))
  return list
end
-- Prints one none line per spawner index per map. door and dist: the nearest door, or nil when there is none.
function ReforgedPreviewNone(index, door, dist)
  REFORGED.previewNone = REFORGED.previewNone or {}
  if REFORGED.previewNone[index] then return end
  REFORGED.previewNone[index] = true
  local short = nil
  if door ~= nil then
    local okN, text = pcall(function() return door:GetFullName() end)
    if okN and text ~= nil then short = string.match(tostring(text), "^(%S+)") end
  end
  print(string.format("[Reforged] preview door %d none within %d nearest=%s class=%s", index, REFORGED_PREVIEW_NEAR,
    dist ~= nil and string.format("%.0f", dist) or "-", short or "-"))
end
-- OMDDoor of a spawner, as door, via, dist. Order: StartingDoor:Get() when it is a valid door (via=get), the door cached for this
-- spawner index, then the nearest door within REFORGED_PREVIEW_NEAR (via=near). Never returns a soft pointer. nil when none.
function ReforgedPreviewDoorOf(spawner, index)
  local okD, doorRef = pcall(function() return spawner.StartingDoor end)
  if okD and doorRef ~= nil then
    local okG, door = pcall(function() return doorRef:Get() end)
    if okG and door ~= nil then
      local okV, valid = pcall(function() return door:IsValid() end)
      if okV and valid == true then return door, "get", nil end
    end
  end
  REFORGED.previewDoorBy = REFORGED.previewDoorBy or {}
  local cached = REFORGED.previewDoorBy[index]
  if cached ~= nil then return cached.door, "near", cached.dist end
  local list = ReforgedPreviewDoorList()
  local okP, here = pcall(function() return spawner:K2_GetActorLocation() end)
  if not okP or here == nil then
    ReforgedPreviewNone(index, nil, nil)
    return nil
  end
  local best, bestD = nil, math.huge
  for _, d in ipairs(list) do
    local dd = DistanceTo(d, here)
    if dd < bestD then best, bestD = d, dd end
  end
  if best == nil or bestD > REFORGED_PREVIEW_NEAR then
    ReforgedPreviewNone(index, best, best ~= nil and bestD or nil)
    return nil
  end
  REFORGED.previewDoorBy[index] = { door = best, dist = bestD }
  return best, "near", bestD
end
-- Prints one preview door line per door index. Prints again when want changes for that door (REFORGED is reset at map ready).
function ReforgedPreviewLog(index, via, dist, want, readback)
  REFORGED.previewLog = REFORGED.previewLog or {}
  local wantText = tostring(want)
  if REFORGED.previewLog[index] == wantText then return end
  REFORGED.previewLog[index] = wantText
  print(string.format("[Reforged] preview door %d via=%s dist=%s write=%s readback=%s", index, via,
    dist ~= nil and string.format("%.0f", dist) or "-", wantText, tostring(readback)))
end
-- Prints a preview line once per map (REFORGED is reset at map ready).
function ReforgedPreviewWarnOnce(text)
  REFORGED.previewWarn = REFORGED.previewWarn or {}
  if REFORGED.previewWarn[text] then return end
  REFORGED.previewWarn[text] = true
  print("[Reforged] " .. text)
end
-- Writes bIsExpectingMobs on every OMDAISpawner door: true when planned[index] is set, else false.
-- Returns marked, written, failed: doors marked true, doors written without error, writes that raised an error.
-- Does nothing outside Reforged.
function ReforgedPreviewWrite(planned)
  if QueueBlockMode() ~= "reforged" then return 0, 0, 0 end
  local okF, spawners = pcall(FindAllOf, "OMDAISpawner")
  if not okF or not spawners then return 0, 0, 0 end
  local marked, written, failed = 0, 0, 0
  for _, spawner in ipairs(spawners) do
    pcall(function()
      local okI, raw = pcall(function() return tonumber(spawner.indexInLevel) end)
      local index = okI and raw or nil
      if index == nil then return end
      local door, via, dist = ReforgedPreviewDoorOf(spawner, index)
      if door == nil then
        ReforgedPreviewWarnOnce("preview door ref unreadable")
        return
      end
      local want = planned[index] == true
      local okW, errW = pcall(function() door.bIsExpectingMobs = want end)
      if not okW then
        failed = failed + 1
        ReforgedPreviewWarnOnce("preview door write failed: " .. tostring(errW))
        return
      end
      written = written + 1
      if want then marked = marked + 1 end
      local okR, readback = pcall(function() return door.bIsExpectingMobs end)
      local readText = "error"
      if okR then readText = tostring(readback) end
      ReforgedPreviewLog(index, via, dist, want, readText)
    end)
  end
  return marked, written, failed
end
-- Records the planned door indexes of round r, writes the marks and emits one preview event. list: door indexes (repeats allowed).
function ReforgedPreviewSet(r, list)
  local set, sorted = {}, {}
  for _, d in ipairs(list) do
    if set[d] == nil then set[d] = true; sorted[#sorted + 1] = d end
  end
  table.sort(sorted)
  REFORGED.previewRound = r
  REFORGED.previewDoors = set
  REFORGED.previewList = sorted
  if REFORGED_PREVIEW ~= true then return end
  local _, written, failed = ReforgedPreviewWrite(set)
  WatchEmit("preview", { round = r, doors = WatchList(sorted), written = written, failed = failed })
end
-- Called from ReforgedStep with the hoard state. A change into build phase writes the current round's marks again.
function ReforgedPreviewPhase(released, reason)
  local phase = (released == true) and "released" or tostring(reason)
  local was = REFORGED.previewPhase
  REFORGED.previewPhase = phase
  if phase == "build-phase" and was ~= "build-phase" and REFORGED_PREVIEW == true and REFORGED.previewDoors ~= nil then
    ReforgedPreviewWrite(REFORGED.previewDoors)
  end
end
-- preview on|off|status (developer command). off clears the marks on every door; on writes the current round's marks again.
function ReforgedPreviewCommand(arg1)
  if arg1 == "on" then
    REFORGED_PREVIEW = true
    if REFORGED.previewDoors ~= nil then ReforgedPreviewWrite(REFORGED.previewDoors) end
    print("[Reforged] preview on")
  elseif arg1 == "off" then
    REFORGED_PREVIEW = false
    pcall(ReforgedWispClearAuto, "preview-off")
    ReforgedPreviewWrite({})
    print("[Reforged] preview off")
  elseif arg1 == nil or arg1 == "" or arg1 == "status" then
    print(string.format("[Reforged] preview on=%s round=%s doors=%s", tostring(REFORGED_PREVIEW), tostring(REFORGED.previewRound or "none"),
      JoinOrNone(REFORGED.previewList or {})))
  else
    print("[Reforged] command rejected: use preview on|off|status")
  end
end
-- Builds round REFORGED.round + 1: sets the cap, emits the plan event and queues one DoorSpawn call per entry. Returns true when it
-- built the round. With no usable doors it changes nothing and returns false, so the next pass tries again.
-- The hoard gate holds the calls until G, and the pace queue spaces them. Entry i uses the usable door (doorStart + i) in turn.
function ReforgedBuildRound()
  -- The seed is set at map ready. A round built before that is thrown away, so it changes nothing here.
  if REFORGED.seed == nil or REFORGED.seed == 0 then
    print("[Reforged] reforged round build skipped: map not ready")
    return false
  end
  -- No usable doors yet (the doors can be unknown at map start): nothing changes, and the waiting line is printed at most once per 10 s.
  if #GetSpawnerIndexes() == 0 then
    local now = os.time()
    if REFORGED.waitAt == nil or now - REFORGED.waitAt >= 10 then
      REFORGED.waitAt = now
      print("[Reforged] reforged round=" .. tostring(REFORGED.round + 1) .. " waiting: no usable doors")
    end
    return false
  end
  -- Reforged rules: round-end coins, rift regen and the coin cut check. REFORGED.round is still the round that ended.
  pcall(ReforgedRulesRoundEnd)
  REFORGED.round = REFORGED.round + 1
  pcall(CurveRoundCheck, REFORGED.round)
  local r, seed = REFORGED.round, REFORGED.seed
  local plan = ReforgedPlan(r, seed)
  REFORGED.last = plan
  REFORGED.lastBuild = os.time()
  -- The map boss of this round fires at its combat start (ReforgedMapBossCombatStart). A new plan replaces an old pending one.
  REFORGED.mapBossPending = plan.mapBoss and { round = r, action = plan.mapBoss } or nil
  REFORGED_GAP_MULT = tonumber(plan.gapMult) or 1
  REFORGED_REINFORCE = plan.reinforce
  SPAWN_CAP = plan.cap
  local pairsOut = WatchList({})
  for i, e in ipairs(plan.entries) do pairsOut[i] = WatchList({ e.proto, e.count }) end
  -- The door calls use the expanded list: promoted counts are spawned as their promoted protos.
  local spawn = ReforgedExpandPromote(plan.entries)
  local spawnOut = WatchList({})
  for i, e in ipairs(spawn) do spawnOut[i] = WatchList({ e.proto, e.count }) end
  WatchEmit("plan", { round = r, size = plan.size, cap = plan.cap, promote = plan.promote, seed = seed, level = REFORGED.level or WatchNull, entries = pairsOut, spawn = spawnOut,
    source = plan.source or "generator", stockRound = plan.stockRound or WatchNull, stockIter = plan.stockIter or WatchNull, mapBoss = plan.mapBoss or WatchNull })
  print(string.format("[Reforged] reforged round=%d size=%d cap=%d entries=%d spawn=%d seed=%s", r, plan.size, plan.cap, #plan.entries, #spawn, tostring(seed)))
  local doors = GetSpawnerIndexes()
  local start = REFORGED.doorStart or 0
  local planned = {}
  local protosBy = {} -- The protos planned at each door this round (the preview kinds read them)
  for i, e in ipairs(spawn) do
    local door = doors[(start + i - 1) % #doors + 1]
    if plan.pinDoor == true then door = doors[start % #doors + 1] end
    if e.door ~= nil then
      local matched = false
      for _, d in ipairs(doors) do
        if d == e.door then door = d; matched = true end
      end
      -- Hellbat flyer rule: a Hellbat entry keeps its stock flyer door (BP_Door_Forcefield). Other protos never do.
      if not matched and type(e.proto) == "string" and e.proto:sub(1, 7) == "Hellbat" then
        local sp = FindSpawnerByIndex(e.door)
        if sp ~= nil then
          local okU, usable, why = pcall(DoorUsable, sp)
          if okU and usable == false and why == "flyer-door" then door = e.door end
        end
      end
    end
    planned[#planned + 1] = door
    if e.proto ~= nil then
      protosBy[door] = protosBy[door] or {}
      protosBy[door][e.proto] = true
    end
    local row = PROTO_BY_NAME[e.proto]
    if row and (e.boss == true or e.bearer == true) then
      -- A boss call carries its boss round index k on a proxy row. The door sampler reads it to register the pawn.
      -- A bearer entry sets bearer on the same proxy row. The door sampler keeps the pawn.
      local proxy = {}
      if e.boss == true then proxy.bossK = math.floor(r / ReforgedBossEvery()) end
      if e.bearer == true then proxy.bearer = true end
      row = setmetatable(proxy, { __index = row })
    end
    if row then
      DoorSpawn(door, row, e.count)
    else
      print("[Reforged] reforged round=" .. r .. " skipped unknown proto " .. tostring(e.proto))
    end
  end
  REFORGED.doorStart = (start + #spawn) % #doors
  REFORGED.previewProtos = protosBy
  pcall(ReforgedPreviewSet, r, planned)
  -- Break gate: the round blocks the stock break until it is clear.
  if BreakGateActive() then BreakGateSet(true, "round-build") end
  return true
end
-- Round trigger. Called once per pass of the hoard release loop, in pcall, before PaceStep. In Reforged a round starts when the
-- hoard state goes from not-build (map start, or released) to build. A failed read ("no-game-state") changes nothing.
function ReforgedStep()
  if QueueBlockMode() ~= "reforged" then return end
  -- No round before MapReadyFor has reset REFORGED for this map (REFORGED.ready).
  if REFORGED.ready ~= true then return end
  -- Round chain: the round after a round with no break is built here. A failed build is retried next pass.
  if BREAK_ORDER.chain == true then
    if ReforgedBuildRound() then BREAK_ORDER.chain = false end
    return
  end
  local released, reason = HoardReleased()
  pcall(ReforgedPreviewPhase, released, reason)
  if released and not ReforgedTimedNow() then
    REFORGED.inBuild = false
    return
  end
  if released then
    -- A timed break is a round boundary too. The hoard gate is open in it, so the round's calls are not held.
    if REFORGED.inBuild ~= true and ReforgedBuildRound() then REFORGED.inBuild = true end
    return
  end
  if reason ~= "build-phase" or REFORGED.inBuild == true then return end
  if ReforgedBuildRound() then REFORGED.inBuild = true end
end
-- War Scenario map boss (#101 M5). Called at the combat start of a Reforged round (the phase changes into combat).
-- Fires the pending round's map boss once through the coordinator, then clears it.
function ReforgedMapBossCombatStart()
  local p = REFORGED.mapBossPending
  if p == nil then return end
  REFORGED.mapBossPending = nil
  local r, name = p.round, p.action
  local c = coordinator()
  local ok, err = false, "no-coordinator"
  if c ~= nil then
    local okC, errC = pcall(function() c:DoOnslaughtAction(name) end)
    ok, err = okC, errC
  end
  if ok then
    print(string.format("[Reforged] map-boss round=%s action=%s ok=true", tostring(r), tostring(name)))
  else
    print(string.format("[Reforged] map-boss round=%s action=%s ok=false err=%s", tostring(r), tostring(name), tostring(err)))
  end
  WatchEmit("mapboss", { round = r, action = name, ok = ok })
end
-- Adds round to a tick event when the saved mode is reforged. The other modes omit it.
function ReforgedTickFields(fields)
  if QueueBlockMode() == "reforged" then fields.round = REFORGED.round end
  return fields
end
-- reforged-plan <round> [seed]: prints the plan for a round and spawns nothing. The seed defaults to the match seed.
-- Boss reward. ReforgedIsBossName: the proto is in REFORGED_WAVES.bosses. ReforgedBossCoins(k): the payment for boss round index k.
function ReforgedIsBossName(name)
  for _, b in ipairs(REFORGED_WAVES.bosses or {}) do
    if b == name then return true end
  end
  return false
end
function ReforgedBossCoins(k)
  return math.floor(REFORGED_BOSS_COINS * (1 + 0.05 * ((tonumber(k) or 1) - 1)) + 0.5)
end
-- Keeps a boss pawn for the reward. Only in Reforged. Returns true when the pawn was added. A pawn already kept is not added twice.
function ReforgedBossRegister(actor, full, protoName, k)
  if QueueBlockMode() ~= "reforged" then return false end
  if full == nil or REFORGED_BOSSES_LIVE[full] ~= nil then return false end
  REFORGED_BOSSES_LIVE[full] = { actor = actor, k = math.floor(tonumber(k) or 1), proto = tostring(protoName) }
  return true
end
-- One pass. A kept boss that is dead, or no longer valid, is removed and paid once: AddCoin on OMDPlayerController.
-- Outside Reforged the kept pawns are dropped without a payment.
function ReforgedBossStep()
  if next(REFORGED_BOSSES_LIVE) == nil then return end
  if QueueBlockMode() ~= "reforged" then
    for key in pairs(REFORGED_BOSSES_LIVE) do REFORGED_BOSSES_LIVE[key] = nil end
    return
  end
  for key, rec in pairs(REFORGED_BOSSES_LIVE) do
    local okV, valid = pcall(function() return rec.actor:IsValid() end)
    local gone = (not okV) or valid ~= true
    if gone or PawnIsDead(rec.actor) then
      REFORGED_BOSSES_LIVE[key] = nil
      local coins = ReforgedBossCoins(rec.k)
      local paid = false
      pcall(function()
        local pc = FindFirstOf("OMDPlayerController")
        pc:AddCoin(coins)
        paid = true
      end)
      print(string.format("[Reforged] boss reward k=%d coins=%d paid=%s", rec.k, coins, tostring(paid)))
      WatchEmit("boss", { k = rec.k, proto = rec.proto, coins = coins, paid = paid })
    end
  end
end

-- Keeps a banner bearer. Only in Reforged, and only when the round has a reinforce setting (REFORGED_REINFORCE).
-- classicCfg: the reinforce block of a Classic modifier. When it is set, the bearer is kept in Classic instead.
-- Returns true when the pawn was added. A pawn already kept is not added twice.
function ReforgedBearerRegister(actor, full, protoName, door, classicCfg)
  local mode = QueueBlockMode()
  local isClassic = classicCfg ~= nil
  if isClassic then
    if mode ~= "classic" then return false end
  elseif mode ~= "reforged" then
    return false
  end
  if full == nil or REFORGED_BEARERS[full] ~= nil then return false end
  local cfg = isClassic and classicCfg or REFORGED_REINFORCE
  if cfg == nil then return false end
  local rnd = isClassic and CLASSIC_MOD.round or REFORGED.round
  REFORGED_BEARERS[full] = { actor = actor, proto = tostring(protoName), door = door, round = rnd, calls = 0, last = os.time(), cfg = cfg, classic = isClassic }
  local id = ShortName(full)
  print(string.format("[Reforged] reinforce bearer door=%s proto=%s id=%s", tostring(door), tostring(protoName), tostring(id)))
  WatchEmit("reinforce", { state = "bearer", round = rnd, door = door, proto = tostring(protoName), id = id })
  return true
end

-- One pass. A kept bearer that is dead or invalid is removed, and it sends no more calls ("down").
-- A standing bearer sends one call per interval from its door: every, or everyCrowd while 2 or more stand. After cfg.limit
-- calls it is removed ("limit"). The protos cycle through cfg.protos. Outside Reforged the kept bearers are dropped with no call.
function ReforgedBearerStep()
  if next(REFORGED_BEARERS) == nil then return end
  -- Reforged keeps its bearers. Classic keeps only the Classic ones. Every other bearer is dropped with no call.
  local mode = QueueBlockMode()
  for key, rec in pairs(REFORGED_BEARERS) do
    local keep = (mode == "reforged" and rec.classic ~= true) or (mode == "classic" and rec.classic == true)
    if not keep then REFORGED_BEARERS[key] = nil end
  end
  if next(REFORGED_BEARERS) == nil then return end
  local function gone(actor)
    local okV, valid = pcall(function() return actor:IsValid() end)
    if not okV or valid ~= true then return true end
    local okD, dead = pcall(PawnIsDead, actor)
    return (not okD) or dead == true
  end
  -- Pass 1: count the standing bearers and remove the gone ones. The interval depends on the count.
  local standing, downs, keys = 0, {}, {}
  for key, rec in pairs(REFORGED_BEARERS) do
    keys[#keys + 1] = key
    if gone(rec.actor) then downs[#downs + 1] = key else standing = standing + 1 end
  end
  for _, key in ipairs(downs) do
    local rec = REFORGED_BEARERS[key]
    REFORGED_BEARERS[key] = nil
    print(string.format("[Reforged] reinforce down door=%s calls=%d", tostring(rec.door), rec.calls))
    WatchEmit("reinforce", { state = "down", round = REFORGED.round, door = rec.door, calls = rec.calls })
  end
  -- Pass 2: limit or call for each standing bearer.
  local now = os.time()
  for _, key in ipairs(keys) do
    local rec = REFORGED_BEARERS[key]
    if rec ~= nil then
      local cfg = rec.cfg
      local interval = (standing >= 2) and cfg.everyCrowd or cfg.every
      if rec.calls >= cfg.limit then
        REFORGED_BEARERS[key] = nil
        print(string.format("[Reforged] reinforce limit door=%s calls=%d", tostring(rec.door), rec.calls))
        WatchEmit("reinforce", { state = "limit", round = REFORGED.round, door = rec.door, calls = rec.calls })
      elseif now - rec.last >= interval then
        rec.calls = rec.calls + 1
        rec.last = now
        local proto = cfg.protos[((rec.calls - 1) % #cfg.protos) + 1]
        local row = PROTO_BY_NAME[proto]
        if row and rec.classic == true then
          -- A Classic bearer's reinforcement call is a Classic modifier call: it goes through the pace queue.
          row = setmetatable({ classicMod = true }, { __index = row })
        end
        if row then
          local okC, errC = pcall(DoorSpawn, rec.door, row, cfg.count)
          if not okC then print("[Reforged] reinforce call error: " .. tostring(errC)) end
        end
        print(string.format("[Reforged] reinforce call door=%s proto=%s count=%s n=%d standing=%d", tostring(rec.door), proto, tostring(cfg.count), rec.calls, standing))
        WatchEmit("reinforce", { state = "call", round = REFORGED.round, door = rec.door, proto = proto, count = cfg.count, n = rec.calls, standing = standing })
      end
    end
  end
end

-- Reforged rift, coin and progression rules. Design approved 2026-10-18.
-- Every rule acts only in Reforged (QueueBlockMode() == "reforged"). Classic and Manual get no write and no payment.
-- Round end = the build of the next round in ReforgedBuildRound: the phase change to build after combat (ReforgedStep).
-- Values here are the stock or approved defaults. The settings rows (SETTINGS_SPEC) overwrite them at match start.
REFORGED_RULES = {
  riftBossCost = 10, riftRegenPerRound = 0, coinReduction = "floor50", roundCoins = "on",
  roundCoinBase = 300, roundCoinStep = 20, riftStart = 20, moneybagsCoins = 500,
  rift = nil,          -- last RiftPoints seen by the poll. nil = no baseline yet
  cause = nil,         -- cause of the next rift change: regen or boss-adjust. nil = game
  bossPending = 0,     -- boss pawns that entered the rift since the last poll (riftBossCost ~= 10 only)
  coinStock = nil,     -- EndlessCoinReductionPerWave as the game set it. Read before the first write of a map
  coinWritten = false, -- true when a write of EndlessCoinReductionPerWave is still to be undone
  mb = {},             -- door-spawned Moneybags kept for the 500-coin pickup: full name -> { actor }
  riftLocs = nil,      -- OMDRift locations {X,Y,Z} for the death check. nil = not read yet. Cleared per map
}

do
  -- A pawn that enters the rift. A kept Moneybags is dropped without a payout first.
  -- A boss pawn changes only the boss cost. The native loss runs in the same call,
  -- so the poll sees it and applies the difference. Wisps and other classes are not bosses.
  local okH = SafeRegisterHook("/Script/OMD.OMDAICharacter:NetMulticast_EnteredRift", function(self)
    pcall(function()
      if QueueBlockMode() ~= "reforged" then return end
      pcall(ReforgedMoneybagsRift, self)
      if REFORGED_RULES.riftBossCost == 10 then return end
      if ReforgedIsRiftBoss(self) then REFORGED_RULES.bossPending = REFORGED_RULES.bossPending + 1 end
    end)
  end)
  print("[Reforged] rules rift-boss hook registered=" .. tostring(okH))
end

-- The native rift-boss protos that cost 10 (Q2 table). The four _Scramble rows are
-- matched by "Boss" in the name. That match is inferred; their exact names are not checked here.
REFORGED_RIFT_BOSSES = { WraithBoss = true, OgreBasher = true, OrcBoss = true, KoboldKing = true, HellbatBoss = true }
function ReforgedIsRiftBoss(actor)
  local okP, pn = pcall(function() return actor:GetProtoName():ToString() end)
  if not okP or type(pn) ~= "string" then return false end
  return REFORGED_RIFT_BOSSES[pn] == true or pn:find("Boss", 1, true) ~= nil
end

-- The HUD rift value (OMDGameState RiftPoints). nil when the read fails.
function ReforgedRiftRead()
  local okG, gs = pcall(FindFirstOf, "OMDGameState")
  if not okG or not gs then return nil end
  local okV, valid = pcall(function() return gs:IsValid() end)
  if not okV or valid ~= true then return nil end
  local okR, v = pcall(function() return gs.RiftPoints end)
  if okR and type(v) == "number" then return v end
  return nil
end

-- Adds delta (or subtracts -delta) rift points through the player controller. cause is kept for the next rift event.
function ReforgedRiftChange(delta, cause)
  if delta == 0 then return false end
  local okP, pc = pcall(FindFirstOf, "OMDPlayerController")
  if not okP or not pc then print("[Reforged] rift " .. tostring(cause) .. ": no player controller"); return false end
  local ok, err
  if delta > 0 then ok, err = pcall(function() pc:AddRiftPoints(delta) end)
  else ok, err = pcall(function() pc:SubtractRiftPoints(-delta) end) end
  print(string.format("[Reforged] rift %s delta=%d set=%s err=%s", tostring(cause), delta, tostring(ok), ok and "-" or tostring(err)))
  if ok then REFORGED_RULES.cause = cause end
  return ok
end

-- One poll pass, every pass in Reforged (called by OMDRulesStep). Emits a rift event on each change the mod sees, then applies
-- the boss difference for each boss that entered (riftBossCost ~= 10). The adjust shows up as the next event (cause boss-adjust).
-- Called by ReforgedRulesStep.
function ReforgedRiftPass()
  local R = REFORGED_RULES
  local cur = ReforgedRiftRead()
  if cur == nil then return end
  if R.rift == nil then R.rift = cur end
  if cur ~= R.rift then
    WatchEmit("rift", { prev = R.rift, cur = cur, round = REFORGED.round, cause = R.cause or "game" })
    R.cause = nil
    R.rift = cur
  end
  if R.bossPending > 0 then
    local n = R.bossPending
    R.bossPending = 0
    -- The stock boss cost is 10. Each boss lost 10, so the difference is 10 - riftBossCost per boss (positive = add back).
    local delta = n * (10 - R.riftBossCost)
    if delta ~= 0 then ReforgedRiftChange(delta, "boss-adjust") end
  end
end

-- Pays amount to every player controller once. Emits one coin event per payout. Returns the number of payouts.
function ReforgedPayAll(kind, amount)
  local okA, list = pcall(FindAllOf, "OMDPlayerController")
  local n = 0
  if not okA or type(list) ~= "table" then print("[Reforged] coin " .. tostring(kind) .. ": no player controllers"); return 0 end
  for _, pc in ipairs(list) do
    local okV, valid = pcall(function() return pc:IsValid() end)
    if okV and valid == true then
      local ok, err = pcall(function() pc:AddCoin(amount) end)
      print(string.format("[Reforged] coin %s amount=%d round=%s set=%s err=%s", tostring(kind), amount, tostring(REFORGED.round), tostring(ok), ok and "-" or tostring(err)))
      if ok then
        n = n + 1
        WatchEmit("coin", { kind = kind, amount = amount, round = REFORGED.round })
      end
    end
  end
  return n
end

-- Round coins: base + step * round, once per round end, to every player. Round 0 (no round ended) pays nothing.
function ReforgedRoundCoinsPay(r)
  local R = REFORGED_RULES
  if R.roundCoins ~= "on" then return end
  local amount = R.roundCoinBase + R.roundCoinStep * r
  ReforgedPayAll("round", amount)
end

-- Rift regen: at round end, add riftRegenPerRound, never above riftStart (20).
function ReforgedRiftRegen()
  local R = REFORGED_RULES
  if R.riftRegenPerRound <= 0 then return end
  local cur = ReforgedRiftRead()
  if cur == nil then print("[Reforged] rift regen skipped: no game state"); return end
  local room = R.riftStart - cur
  if room <= 0 then print(string.format("[Reforged] rift regen skipped: rift=%s at start %d", tostring(cur), R.riftStart)); return end
  ReforgedRiftChange(math.min(R.riftRegenPerRound, room), "regen")
end

-- k = the per-wave step count of the native reduction: waves past the iteration's last wave.
-- Native: f = 1 - k * EndlessCoinReductionPerWave, k = CurrentWave - EndlessMaxWavePerIteration when EndlessIteration > 0.
-- Returns nil when a read fails.
function ReforgedCoinSteps()
  local okG, gs = pcall(FindFirstOf, "OMDGameState")
  if not okG or not gs then return nil end
  local okV, valid = pcall(function() return gs:IsValid() end)
  if not okV or valid ~= true then return nil end
  local okI, it = pcall(function() return gs.EndlessIteration end)
  local okW, wave = pcall(function() return gs.CurrentWave end)
  local okM, last = pcall(function() return gs.EndlessMaxWavePerIteration end)
  if not (okI and okW and okM) or type(it) ~= "number" or type(wave) ~= "number" or type(last) ~= "number" then return nil end
  if it <= 0 then return 0 end
  return math.max(0, wave - last)
end

-- Writes EndlessCoinReductionPerWave on the Difficulty Manager. want: stock, floor50 or off.
-- off writes 0. stock writes the game value. floor50 writes min(stock, 0.5 / k) when k > 0, so the coin value
-- f = 1 - k * written stays at 0.5 or more. While k * stock < 0.5 it writes the game value.
function ReforgedCoinWrite(want)
  local R = REFORGED_RULES
  local okD, dm = pcall(FindFirstOf, "OMDDifficultyManager")
  if not okD or not dm then print("[Reforged] coin reduction: no difficulty manager"); return false end
  local okV, valid = pcall(function() return dm:IsValid() end)
  if not okV or valid ~= true then print("[Reforged] coin reduction: difficulty manager not valid"); return false end
  local okR, cur = pcall(function() return dm.EndlessCoinReductionPerWave end)
  if not okR or type(cur) ~= "number" then print("[Reforged] coin reduction: read failed"); return false end
  if R.coinStock == nil then R.coinStock = cur end
  local target = R.coinStock
  if want == "off" then
    target = 0
  elseif want == "floor50" then
    local k = ReforgedCoinSteps()
    if k ~= nil and k > 0 then target = math.min(R.coinStock, 0.5 / k) end
  end
  local ok, err = pcall(function() dm.EndlessCoinReductionPerWave = target end)
  print(string.format("[Reforged] coin reduction %s: EndlessCoinReductionPerWave %s -> %s set=%s err=%s", tostring(want), tostring(cur), tostring(target), tostring(ok), ok and "-" or tostring(err)))
  if ok then R.coinWritten = true end
  return ok
end

-- Undoes ReforgedCoinWrite: writes the game value back. Keeps the flag when the manager is not there yet, so a later pass retries.
function ReforgedCoinRestore(why)
  local R = REFORGED_RULES
  if not R.coinWritten or R.coinStock == nil then R.coinWritten = false; return end
  local okD, dm = pcall(FindFirstOf, "OMDDifficultyManager")
  if not okD or not dm then return end
  local ok, err = pcall(function() dm.EndlessCoinReductionPerWave = R.coinStock end)
  print(string.format("[Reforged] coin reduction restore %s (%s) set=%s err=%s", tostring(R.coinStock), why, tostring(ok), ok and "-" or tostring(err)))
  if ok then R.coinWritten = false; R.coinStock = nil end
end

-- Round end: called once from ReforgedBuildRound before the next round is counted. REFORGED.round is the round that ended.
-- Each step runs once per round end (REFORGED.ruleEnd). Round 0 has no end.
function ReforgedRulesRoundEnd()
  if QueueBlockMode() ~= "reforged" then return end
  local R = REFORGED_RULES
  local r = REFORGED.round
  if r < 1 or REFORGED.ruleEnd == r then return end
  REFORGED.ruleEnd = r
  print(string.format("[Reforged] rules round end round=%d", r))
  pcall(ReforgedRoundCoinsPay, r)
  pcall(ReforgedRiftRegen)
  if R.coinReduction == "floor50" then pcall(ReforgedCoinWrite, "floor50") end
end

-- A door-spawned Moneybags. Kept only when the counted marker (+0x848) reads 0: a door pawn. Native pawns with a
-- coordinator marker are not kept, so they are not paid twice. An unreadable marker is not kept.
-- classic: true when the call comes from a Classic modifier. Then the Moneybags is kept in Classic only.
function ReforgedMoneybagsRegister(actor, full, classic)
  local mode = QueueBlockMode()
  if classic == true then
    if mode ~= "classic" then return false end
  elseif mode ~= "reforged" then
    return false
  end
  if full == nil or REFORGED_RULES.mb[full] ~= nil then return false end
  local okM, marker = pcall(function() return actor.ReforgedSpawnCoord end)
  if not okM or marker ~= 0 then
    print(string.format("[Reforged] moneybags not kept: marker=%s", okM and tostring(marker) or "unreadable"))
    return false
  end
  REFORGED_RULES.mb[full] = { actor = actor }
  return true
end

-- OMDRift locations for the death check. Read when riftLocs is nil or empty. Returns a list, which can be empty.
-- Each entry is {X,Y,Z} from K2_GetActorLocation. Only valid actors with a readable location are kept.
function ReforgedRiftLocs()
  local R = REFORGED_RULES
  if R.riftLocs == nil or #R.riftLocs == 0 then
    local list = {}
    local okA, found = pcall(FindAllOf, "OMDRift")
    if okA and type(found) == "table" then
      for _, rift in ipairs(found) do
        local okL, x, y, z = pcall(function()
          if rift:IsValid() ~= true then return nil end
          local v = rift:K2_GetActorLocation()
          return v.X, v.Y, v.Z
        end)
        if okL and type(x) == "number" and type(y) == "number" and type(z) == "number" then
          list[#list + 1] = { X = x, Y = y, Z = z }
        end
      end
    end
    R.riftLocs = list
  end
  return R.riftLocs
end

-- True when loc (a table with X, Y, Z) is within 600 units (3D) of any rift. False for nil or no rift locations.
function ReforgedAtRift(loc)
  if loc == nil then return false end
  for _, r in ipairs(ReforgedRiftLocs()) do
    local dx, dy, dz = loc.X - r.X, loc.Y - r.Y, loc.Z - r.Z
    if dx * dx + dy * dy + dz * dz <= 600 * 600 then return true end
  end
  return false
end

-- A kept Moneybags that enters the rift is removed without a payout. Paid on death only.
-- The rift hook (NetMulticast_EnteredRift) calls this. The death check in ReforgedMoneybagsStep also finds rift
-- arrivals by position, because the hook did not fire in the live run of 2026-10-18.
-- The record key is the full name, the same key ReforgedMoneybagsRegister uses. Only in Reforged.
function ReforgedMoneybagsRift(actor)
  if QueueBlockMode() ~= "reforged" and QueueBlockMode() ~= "classic" then return false end
  local okF, full = pcall(function() return actor:GetFullName() end)
  if not okF or type(full) ~= "string" or REFORGED_RULES.mb[full] == nil then return false end
  REFORGED_RULES.mb[full] = nil
  print("[Reforged] moneybags entered rift, not paid")
  WatchEmit("moneybags", { outcome = "rift", round = REFORGED.round })
  return true
end

-- One pass. Paid on death only.
-- A kept Moneybags that is dead, or no longer valid (a dead pawn that was destroyed), is removed.
-- If its location reads and it is at a rift (ReforgedAtRift), it is not paid. Otherwise it is paid once.
-- A failed location read (a destroyed actor) pays as before.
function ReforgedMoneybagsStep()
  for key, rec in pairs(REFORGED_RULES.mb) do
    local okV, valid = pcall(function() return rec.actor:IsValid() end)
    if not (okV and valid == true) or PawnIsDead(rec.actor) then
      REFORGED_RULES.mb[key] = nil
      local okL, x, y, z = pcall(function()
        local v = rec.actor:K2_GetActorLocation()
        return v.X, v.Y, v.Z
      end)
      if okL and type(x) == "number" and type(y) == "number" and type(z) == "number" and ReforgedAtRift({ X = x, Y = y, Z = z }) then
        print("[Reforged] moneybags died at rift, not paid")
        WatchEmit("moneybags", { outcome = "rift", round = REFORGED.round })
      else
        ReforgedPayAll("moneybags", REFORGED_RULES.moneybagsCoins)
        WatchEmit("moneybags", { outcome = "paid", round = REFORGED.round })
      end
    end
  end
end

-- One pass of the rules (called from the hoard release loop). Outside Reforged it only restores a coin write the mod made.
function ReforgedRulesStep()
  if QueueBlockMode() ~= "reforged" then
    if REFORGED_RULES.coinWritten then ReforgedCoinRestore("not reforged") end
    -- Classic: only the Moneybags that a Classic modifier kept is paid on death. No rift pass.
    if QueueBlockMode() == "classic" then ReforgedMoneybagsStep() end
    return
  end
  ReforgedMoneybagsStep()
  ReforgedRiftPass()
end

-- Map ready for any mode: undo the coin write of the previous map and clear the per-map rule state.
function ReforgedRulesMapReset()
  local R = REFORGED_RULES
  ReforgedCoinRestore("map ready")
  R.rift, R.cause, R.bossPending, R.mb, R.riftLocs = nil, nil, 0, {}, nil
end

function ReforgedPlanCommand(arg1, arg2)
  local r = arg1 ~= nil and arg1:match("^%d+$") and tonumber(arg1) or nil
  local reject = "[Reforged] command rejected: reforged-plan needs a round 1-10000 and an optional whole seed"
  if r == nil or r < 1 or r > 10000 then print(reject); return end
  local seed = REFORGED.seed
  if arg2 ~= nil and arg2 ~= "" then
    seed = arg2:match("^%-?%d+$") and math.tointeger(tonumber(arg2)) or nil
    if seed == nil then print(reject); return end
  end
  -- Preview: the modifier hook reads the force and writes nothing (no force clear, no last, no watch event).
  REFORGED_MOD.preview = true
  local okP, plan = pcall(ReforgedPlan, r, seed)
  REFORGED_MOD.preview = false
  if not okP then print("[Reforged] reforged-plan failed: " .. tostring(plan)); return end
  local total = 0
  for _, e in ipairs(plan.entries) do total = total + e.count end
  print(string.format("[Reforged] reforged-plan round=%d seed=%s size=%s cap=%s promote=%s entries=%d total=%d",
    r, tostring(seed), tostring(plan.size), tostring(plan.cap), tostring(plan.promote), #plan.entries, total))
  for i, e in ipairs(plan.entries) do
    print(string.format("[Reforged] reforged-plan entry %d proto=%s count=%s promote=%s", i, tostring(e.proto), tostring(e.count), tostring(e.promote)))
  end
end
-- reforged-round-next <n>: the next Reforged round built is round n. Sets the counter to n - 1. Developer command.
function ReforgedRoundNextCommand(arg1)
  local n = arg1 ~= nil and arg1:match("^%d+$") and tonumber(arg1) or nil
  if n == nil or n < 1 or n > 1000 then
    print("[Reforged] command rejected: reforged-round-next needs a round 1-1000")
    return
  end
  REFORGED.round = n - 1
  print("[Reforged] reforged-round-next next=" .. tostring(n))
end

-- reforged-round: the round counter, the match seed, the spawn cap and the last plan.
function ReforgedRoundCommand()
  print(string.format("[Reforged] reforged-round round=%d inBuild=%s seed=%s spawnCap=%s", REFORGED.round, tostring(REFORGED.inBuild == true),
    tostring(REFORGED.seed), SPAWN_CAP and tostring(SPAWN_CAP) or "off"))
  local p = REFORGED.last
  if p == nil then print("[Reforged] reforged-round last=none"); return end
  local total = 0
  for _, e in ipairs(p.entries) do total = total + e.count end
  print(string.format("[Reforged] reforged-round last round=%s size=%s cap=%s promote=%s entries=%d total=%d",
    tostring(p.round), tostring(p.size), tostring(p.cap), tostring(p.promote), #p.entries, total))
end

-- modifier: status, list, force <id>, clear, on|off. Forced ids apply to the next Reforged round plan.
function ReforgedModifierCommand(arg1, arg2)
  local lib = REFORGED_MOD.lib
  if arg1 == nil or arg1 == "" then
    print(string.format("[Reforged] modifier status loaded=%s on=%s chance=%s minRound=%s last=%s forced=%s", tostring(lib ~= nil),
      tostring(REFORGED_MOD.on), tostring(REFORGED_MOD.chance), tostring(REFORGED_MOD.minRound), tostring(REFORGED_MOD.last or "none"),
      tostring(REFORGED_MOD.forced or "none")))
  elseif arg1 == "list" then
    if lib == nil then print("[Reforged] command rejected: modifier module not loaded"); return end
    for _, row in ipairs(lib.List()) do
      print(string.format("[Reforged] modifier list id=%s kind=%s weight=%s available=%s", tostring(row.id), tostring(row.kind),
        tostring(row.weight), tostring(row.available)))
    end
  elseif arg1 == "force" then
    local rec = lib and lib.Get(arg2 or "")
    if not rec or rec.available ~= true then
      print("[Reforged] command rejected: modifier force needs an available id (modifier list)")
      return
    end
    REFORGED_MOD.forced = arg2
    print("[Reforged] modifier force=" .. tostring(arg2) .. " (next Reforged round)")
  elseif arg1 == "clear" then
    REFORGED_MOD.forced = nil
    REFORGED_MOD.last = nil
    print("[Reforged] modifier clear")
  elseif arg1 == "on" or arg1 == "off" then
    REFORGED_MOD.on = (arg1 == "on")
    print("[Reforged] modifier on=" .. tostring(REFORGED_MOD.on))
  else
    print("[Reforged] command rejected: use modifier, modifier list, modifier force <id>, modifier clear, modifier on|off")
  end
end
-- Scaled wave: count pawns of the base type; promotePct percent of them are the promotion type.
-- The promoted pawns are spread evenly through the wave (pawn i is promoted when floor(i*pct/100) grows).
-- Growth is the count itself: the director picks a larger count for a later step.
local SCALE_BASE, SCALE_PROMOTED = "OrcMedium", "OrcHeavy"
local function ScaledWave(count, promotePct, spacingSeconds)
  local spacing = math.max(10, tonumber(spacingSeconds) or 10)
  local doors = GetSpawnerIndexes()
  if #doors == 0 then print("[Reforged] wave rejected: no live door spawners"); return end
  local promoted = 0
  WaveBegin(string.format("scaled x%d promote=%d%%", count, promotePct), math.max(0, (count - 1) * spacing) + 8)
  for i = 1, count do
    local isPromoted = math.floor(i * promotePct / 100) > math.floor((i - 1) * promotePct / 100)
    if isPromoted then promoted = promoted + 1 end
    local row = PROTO_BY_NAME[isPromoted and SCALE_PROMOTED or SCALE_BASE]
    -- Cycle the doors in order. Random picks repeated one door six times in ten and some pawns were not tracked.
    local door = doors[(i - 1) % #doors + 1]
    After((i - 1) * spacing * 1000, function() DoorSpawn(door, row, 1) end)
  end
  print(string.format("[Reforged] scaled wave scheduled count=%d promotePct=%d requested base=%s x%d promoted=%s x%d spacing=%ds",
    count, promotePct, SCALE_BASE, count - promoted, SCALE_PROMOTED, promoted, spacing))
end

-- Distinct wave: N different types, each once, on random doors. Same spacing as wave.
local DISTINCT_TYPES = { "OrcMedium", "OrcLight", "OrcHeavy", "OrcArcher", "Kobold", "Ogre", "Troll", "GnollAssassin" }
local function DistinctWave(count)
  local doors = GetSpawnerIndexes()
  if #doors == 0 then
    print("[Reforged] wave rejected: no live door spawners")
    return
  end
  local pool = {}
  for _, name in ipairs(DISTINCT_TYPES) do pool[#pool + 1] = name end
  for i = #pool, 2, -1 do
    local j = math.random(i)
    pool[i], pool[j] = pool[j], pool[i]
  end
  local scheduledCount = math.min(count, #pool)
  WaveBegin(string.format("distinct x%d", scheduledCount), math.max(0, (scheduledCount - 1) * 10) + 8)
  for i = 1, scheduledCount do
    local name = pool[i]
    local row = PROTO_BY_NAME[name]
    local door = doors[math.random(#doors)]
    After((i - 1) * 10000, function()
      print(string.format("[Reforged] distinct %d/%d type=%s door=%d", i, count, name, door))
      DoorSpawn(door, row, 1)
    end)
  end
  print(string.format("[Reforged] distinct wave scheduled count=%d spacing=10s", scheduledCount))
end

-- Sweep: spawn each AI proto once at one door, one at a time, with a delay between.
-- Logs each type's result, so a type that does not spawn in this level shows as no new pawn.
local function SweepAll(door, delaySeconds)
  for i, row in ipairs(PROTOS) do
    After((i - 1) * delaySeconds * 1000, function()
      print(string.format("[Reforged] sweep %d/%d type=%s door=%d", i, #PROTOS, row.name, door))
      DoorSpawn(door, row, 1)
    end)
  end
  print(string.format("[Reforged] sweep scheduled types=%d door=%d delay=%ds", #PROTOS, door, delaySeconds))
end

-- Takeover: switch the native door spawners off (bIsActive false) so only
-- director spawns happen. "off" restores each spawner's saved stock value.
local takeoverSaved = {}
local function Takeover(on)
  ExecuteInGameThread(function()
    local ok, list = pcall(FindAllOf, "OMDAISpawner")
    if not ok or not list then print("[Reforged] takeover: no spawner list"); return end
    for _, sp in ipairs(list) do
      pcall(function()
        local idx = tostring(sp.indexInLevel)
        local before = sp.bIsActive
        if on then
          takeoverSaved[idx] = before
          sp.bIsActive = false
        else
          local v = takeoverSaved[idx]
          if v == nil then v = true end
          sp.bIsActive = v
        end
        print(string.format("[Reforged] takeover %s spawner=%s bIsActive %s -> %s",
          on and "on" or "off", idx, tostring(before), tostring(sp.bIsActive)))
      end)
    end
  end)
end

local function FeignPlayer()
  local pc, pawn
  pcall(function() pc = FindFirstOf("OMDPlayerController") end)
  if pc and pc:IsValid() then pcall(function() pawn = pc.Pawn end) end
  if not pawn or not pawn:IsValid() then
    local ok, pawns = pcall(FindAllOf, "OMDPlayerCharacter")
    if ok and pawns then
      for _, candidate in ipairs(pawns) do
        if candidate and candidate:IsValid() then pawn = candidate; break end
      end
    end
  end
  if not pawn or not pawn:IsValid() then
    print("[Reforged] feign-death failed: player pawn unavailable")
    return
  end
  local moveType = "?"
  local active = false
  pcall(function() moveType = pawn.MoveAbilityType end)
  pcall(function() active = pawn.bMoveAbilityActive end)
  if tostring(moveType) ~= "3" and not tostring(moveType):find("FeignDeath") then
    print("[Reforged] feign-death skipped: movement ability is " .. tostring(moveType) .. ", expected FeignDeath(3)")
    return
  end
  if active == true or tostring(active) == "true" then return end
  local ok, err = pcall(function() pawn:Server_SetMoveAbilityActive(true) end)
  After(250, function()
    local after = "?"
    pcall(function() after = pawn.bMoveAbilityActive end)
    print(string.format("[Reforged] feign-death request movement=%s call=%s active=%s err=%s",
      tostring(moveType), tostring(ok), tostring(after), tostring(err)))
    ExecuteInGameThread(function() SamplePlayerAggro(pawn, "+0.25s") end)
    After(5000, function()
      ExecuteInGameThread(function() SamplePlayerAggro(pawn, "+5s") end)
    end)
  end)
end

-- wave-amount-at <seconds> <amount>: call SetAllAICharactersAmount that many seconds after the next round start (test only; lifts the ALLOW_NATIVE_QUEUE_EDIT block).
local pendingWaveAmount = nil
local roundFeignHooked = false
local function HookRoundFeign()
  if roundFeignHooked then return end
  roundFeignHooked = true
  -- Registered once at load. The body does nothing unless testing is on. Cause inferred.
  local ok, err = SafeRegisterHook("/Script/OMD.OMDOnslaughtCoordinator:OnslaughtStartGroup", function(self, waitPercent)
    if not TESTING or TESTING_LIGHT then return end
    local now = os.clock()
    if now - lastFeignAttempt < 1.0 then return end
    lastFeignAttempt = now
    print("[Reforged] round start detected; activating Feign Death")
    if pendingWaveAmount then
      local p = pendingWaveAmount
      pendingWaveAmount = nil
      After(p.secs * 1000, function()
        ALLOW_NATIVE_QUEUE_EDIT = true
        print(string.format("[Reforged] wave-amount-at firing amount=%d %ds after round start", p.amount, p.secs))
        SetWaveAmount(p.amount)
      end)
    end
    if TESTING then GameNow(FeignPlayer) end
  end)
  print("[Reforged] round-start Feign Death hook registered=" .. tostring(ok) .. " " .. tostring(err))
end

-- Endless mode chosen on the Play screen. OrcsMustUI writes endless-mode.txt
-- next to director.cmd: classic (no change), manual (the director takes over
-- the native spawners, and the web panel's Manual tab sends the waves), or
-- reforged (the director takes over and the panel server's wave brain decides the waves). A missing file means classic.
local ENDLESS_MODES = { classic = true, manual = true, reforged = true }
-- Changing the native spawners while the level is still streaming in hung the game on the loading card (observed 2026-10-16,
-- Manual mode, Colosseum). The takeover therefore waits until OMDGameState reports a wave, which it does only once the level plays.
-- observed 2026-10-17 (Hidden Dock): CurrentWave read -1 while the loading card was still up, so a wave check alone was not enough.
-- The level counts as playable when CurrentWave >= 1 and the Endless iteration (gsIter in panel-status) is >= 0.
-- The takeover then waits for LEVEL_STABLE_NEEDED playable checks in a row.
local takeoverPending = nil
local LEVEL_STABLE_NEEDED = 3
local levelStable = 0
-- Returns playable, wave text, iter text. The texts are for the log. Global: the watch stream calls it.
function LevelPlayable()
  local gs
  pcall(function() gs = FindFirstOf("OMDGameState") end)
  if not (gs and gs:IsValid()) then return false, "?", "?" end
  local okW, wave = pcall(function() return gs.CurrentWave end)
  local okI, iter = pcall(function() return gs.EndlessIteration end)
  local waveText = okW and tostring(wave) or "?"
  local iterText = okI and tostring(iter) or "?"
  local playable = okW and okI and type(wave) == "number" and wave >= 1 and type(iter) == "number" and iter >= 0
  return playable, waveText, iterText
end
-- Anchor capture. With ANCHOR_FROM_NATIVE, the takeover waits until a counted
-- native pawn stands and takes it as the anchor. anchorCapture is nil when no capture runs. The functions are defined with the anchor block.
ANCHOR_FROM_NATIVE = true
ANCHOR_CAPTURE_TIMEOUT = 60
-- A counted pawn is taken only when it stands at least this far (units, 3D) from every OMDAISpawner (anchor-min-dist 200-5000).
ANCHOR_MIN_DOOR_DIST = 1200
anchorCapture = nil
GameLoop(2000, function()
  if not takeoverPending then return false end
  do
    local function gtBody()
      if not takeoverPending then return end
      if anchorCapture then AnchorCaptureTick(); return end
      local playable, wave, iter = LevelPlayable()
      if not playable then
        if levelStable > 0 then
          levelStable = 0
          print(string.format("[Reforged] level playable check wave=%s iter=%s stable=%d/%d", wave, iter, levelStable, LEVEL_STABLE_NEEDED))
        end
        return
      end
      levelStable = levelStable + 1
      print(string.format("[Reforged] level playable check wave=%s iter=%s stable=%d/%d", wave, iter, levelStable, LEVEL_STABLE_NEEDED))
      if levelStable >= LEVEL_STABLE_NEEDED then
        local mode = takeoverPending
        levelStable = 0
        if AnchorCaptureBegin() then return end
        takeoverPending = nil
        Takeover(true)
        print("[Reforged] mode=" .. mode .. " takeover requested (level playable)")
      end
    end
    gtBody()
  end
  return false
end)
ENDLESS_MODE = "classic"      -- the mode applied at the last map load; panel-status reports it as mode=
local function ApplyEndlessMode()
  -- WAVE_COMMAND_PATH is the global copy of COMMAND_PATH (that local is declared below)
  local path = WAVE_COMMAND_PATH and (WAVE_COMMAND_PATH:gsub("director%.cmd$", "endless-mode.txt"))
  local mode = "classic"
  if path then
    local fh = io.open(path, "r")
    if fh then
      mode = ((fh:read("*l") or ""):gsub("%s+", "")):lower()
      fh:close()
    end
  end
  if not ENDLESS_MODES[mode] then
    print("[Reforged] endless-mode '" .. mode .. "' is unknown; using classic")
    mode = "classic"
  end
  ENDLESS_MODE = mode
  print("[Reforged] mode=" .. mode)
  if mode == "manual" then
    takeoverPending = "manual"
    print("[Reforged] mode=manual: takeover waits until the level is playable; the panel Manual tab drives the waves")
  elseif mode == "reforged" then
    -- The wave brain (panel server) decides each wave from the rules or an LLM command. The panel server starts it when it
    -- sees mode=reforged in panel-status. Untested in game.
    takeoverPending = "reforged"
    print("[Reforged] mode=reforged: takeover waits until the level is playable; the wave brain decides the waves")
  else
    -- Classic never takes over. A takeover or capture pending from an earlier Manual or Reforged level must not carry over.
    takeoverPending = nil
    anchorCapture = nil
  end
end

-- The Endless mode text on the Play screen. The hub shows
-- a display-only TextBlock above the mission list. F6 cycles the mode while the hub is open
-- (EndlessModeKeyPress), and the choice is saved to endless-mode.txt for ApplyEndlessMode at each map load.
local MODE_BOX_NAME = "ReforgedEndlessModeBox"
local MODE_LABELS = { classic = "Classic", manual = "Manual", reforged = "Reforged" }
local lastWrittenMode = nil
local modeTextBlock = nil
local modeTextHub = nil  -- the hub object that modeTextBlock was built for
-- The row widgets (global, not local: the main chunk is near the 200-local limit). Nil fields in fallback.
ModeRow = {}

local function WriteEndlessMode(mode)
  if mode == lastWrittenMode then return end
  local path = WAVE_COMMAND_PATH and (WAVE_COMMAND_PATH:gsub("director%.cmd$", "endless-mode.txt"))
  if not path then print("[Reforged] endless-mode not saved: path not resolved"); return end
  local tmp = path .. ".tmp"
  local fh, err = io.open(tmp, "w")
  if not fh then print("[Reforged] endless-mode not saved: " .. tostring(err)); return end
  fh:write(mode:lower() .. "\n")
  fh:close()
  os.remove(path)
  local renamed, rerr = os.rename(tmp, path)
  if not renamed then print("[Reforged] endless-mode not saved: " .. tostring(rerr)); return end
  lastWrittenMode = mode
  print("[Reforged] endless-mode saved " .. mode)
end

-- Shows the mode in the hub. Row mode (ModeRow.row set): each text goes in its own box. Fallback: all lines go in
-- modeTextBlock. A nil or invalid widget is skipped. The Modifiers box is collapsed for manual.
local function SetModeText(mode)
  if not (modeTextBlock and modeTextBlock:IsValid()) then return end
  local label = MODE_LABELS[mode] or MODE_LABELS.classic
  local modeLine = "Endless: " .. label .. " (F6)"
  -- The modifier setting of this mode (reforged: waveModifiers, classic: modifiersInClassic). Manual has none.
  local hasMods = mode == "reforged" or mode == "classic"
  local modsLine = nil
  if hasMods then
    local key = (mode == "reforged") and "waveModifiers" or "modifiersInClassic"
    modsLine = "Modifiers: " .. ((ModifierSettingRead(key) == "on") and "ON" or "OFF") .. " (F5)"
  end
  local testOn = TEST_MODE == true
  if ModeRow.row == nil then
    local text = modeLine
    if modsLine then text = text .. "\n" .. modsLine end
    if testOn then text = text .. "\nTEST MODE: ON" end
    modeTextBlock:SetText(FText(text))
    return
  end
  -- Row mode. Each call is in pcall.
  local function Put(widget, text)
    if widget == nil or text == nil then return end
    pcall(function()
      if widget:IsValid() then widget:SetText(FText(text)) end
    end)
  end
  local function Show(border, visible)
    if border == nil then return end
    pcall(function()
      if border:IsValid() then border:SetVisibility(visible and 4 or 1) end
    end)
  end
  -- The stock banner (ScaleBox_116, Image_390) stays collapsed while the row shows. Each call is in pcall.
  local function Collapse(w)
    if w == nil then return end
    pcall(function()
      if w:IsValid() then w:SetVisibility(1) end -- 1 = ESlateVisibility::Collapsed
    end)
  end
  Collapse(ModeRow.bannerText)
  Collapse(ModeRow.bannerBg)
  Put(modeTextBlock, modeLine)
  Put(ModeRow.mods, modsLine)
  Put(ModeRow.test, "TEST MODE: ON")
  Show(ModeRow.modeBorder, true)
  Show(ModeRow.modsBorder, hasMods)
  Show(ModeRow.testBorder, testOn)
end

-- Classic -> reforged -> classic. Manual is hidden from F6: a saved manual goes to classic. Any other value gives classic.
function EndlessModeNext(mode)
  if mode == "classic" then return "reforged" end
  if mode == "reforged" then return "classic" end
  if mode == "manual" then return "classic" end
  return "classic"
end

-- The saved mode from endless-mode.txt. A missing or unknown value gives classic.
function ReadEndlessMode()
  local path = WAVE_COMMAND_PATH and (WAVE_COMMAND_PATH:gsub("director%.cmd$", "endless-mode.txt"))
  if not path then return "classic" end
  local fh = io.open(path, "r")
  if not fh then return "classic" end
  local mode = ((fh:read("*l") or ""):gsub("%s+", "")):lower()
  fh:close()
  if ENDLESS_MODES[mode] then return mode end
  return "classic"
end

-- F6 handler. Acts only while the Endless hub is open.
function EndlessModeKeyPress(hubOpen)
  if hubOpen ~= true then
    print("[Reforged] endless-mode key ignored: the Endless hub is not open")
    return
  end
  local nextMode = EndlessModeNext(ReadEndlessMode())
  lastWrittenMode = nil
  WriteEndlessMode(nextMode)
  pcall(SetModeText, nextMode)
  print("[Reforged] endless-mode key F6 -> " .. nextMode)
end

-- F5 toggles the modifier setting of the current Endless mode. Acts only while the Endless hub is open.
-- reforged -> waveModifiers, classic -> modifiersInClassic, manual -> none. The value is saved like the Options row.
function ModifiersKeyPress(hubOpen)
  if hubOpen ~= true then
    print("[Reforged] modifiers key ignored: the Endless hub is not open")
    return
  end
  local mode = ReadEndlessMode()
  local key = nil
  if mode == "reforged" then key = "waveModifiers" elseif mode == "classic" then key = "modifiersInClassic" end
  if key == nil then
    print("[Reforged] modifiers key ignored: no modifier setting in " .. tostring(mode))
    return
  end
  local cur = ModifierSettingRead(key)
  local nextVal = (cur == "on") and "off" or "on"
  local okP, saved = pcall(WriteSettings, key, nextVal)
  local ok = okP and saved == true
  print("[Reforged] modifiers key F5 mode=" .. mode .. " " .. key .. "=" .. nextVal .. " ok=" .. tostring(ok))
  WatchEmit("modifiers-key", { mode = mode, key = key, value = nextVal, ok = ok })
  pcall(SetModeText, mode)
end

local function EndlessHubOpen()
  local okF, hub = pcall(FindFirstOf, "HubScreen_UMG_C")
  if not okF or not hub then return false end
  local okV, valid = pcall(function() return hub:IsValid() end)
  return okV and valid == true
end

local function HubPanelClasses(hub)
  -- diagnostic: how many live widgets of each candidate class the hub holds
  for _, cls in ipairs({ "MissionListEntryProto_UMG_C", "MissionListEntryProto_UMG", "MissionListScrollBox", "ScrollBox", "VerticalBox", "HorizontalBox" }) do
    local okF, list = pcall(FindAllOf, cls)
    local count, inHub = 0, 0
    for _, w in ipairs(okF and list or {}) do
      count = count + 1
      local okN, name = pcall(function() return w:GetFullName() end)
      if okN and name and name:find("HubScreen", 1, true) then inHub = inHub + 1 end
    end
    print(("[Reforged] endless-mode class %s total=%d in-hub=%d"):format(cls, count, inHub))
  end
end

-- The hub's mission list is the ScrollBox holding the most children (the
-- map entries); the text goes into the ScrollBox's parent, above it.
local function FindMissionScroll()
  local okF, list = pcall(FindAllOf, "ScrollBox")
  local best, bestCount = nil, 0
  for _, w in ipairs(okF and list or {}) do
    local okN, name = pcall(function() return w:GetFullName() end)
    if okN and name and name:find("HubScreen", 1, true) then
      local okC, n = pcall(function() return w:GetChildrenCount() end)
      if okC and n and n > bestCount then best, bestCount = w, n end
    end
  end
  return best, bestCount
end

-- True when a and b are the same hub object. Compares GetAddress(); falls back to the full name.
local function SameHub(a, b)
  if a == nil or b == nil then return false end
  local okA, addrA = pcall(function() return a:GetAddress() end)
  local okB, addrB = pcall(function() return b:GetAddress() end)
  if okA and okB and addrA and addrB then return addrA == addrB end
  local okNA, nameA = pcall(function() return a:GetFullName() end)
  local okNB, nameB = pcall(function() return b:GetFullName() end)
  return okNA and okNB and nameA ~= nil and nameA == nameB
end

local modeBoxAttempts = 0
local function BuildEndlessModeBox()
  local hub = FindFirstOf("HubScreen_UMG_C")
  if not hub or not hub:IsValid() then print("[Reforged] endless-mode: hub not found"); return end
  -- Keep the widgets only while they belong to this hub. A rebuilt hub gets new widgets.
  if modeTextBlock and modeTextBlock:IsValid() then
    if SameHub(modeTextHub, hub) then return end
    print("[Reforged] endless-mode text rebuilt for a new hub")
  end
  local scroll, count = FindMissionScroll()
  if not scroll or count < 5 then
    modeBoxAttempts = modeBoxAttempts + 1
    if modeBoxAttempts <= 15 then
      GameDelay(1000, function() BuildEndlessModeBox() end)
      return
    end
    print("[Reforged] endless-mode: no mission list ScrollBox after 15 retries"); return
  end
  modeBoxAttempts = 0
  local container = scroll:GetParent()
  local function Step(label, fn)
    local ok, result = pcall(fn)
    if not ok then print("[Reforged] endless-mode step " .. label .. " failed: " .. tostring(result)) end
    return ok, result
  end
  print("[Reforged] endless-mode list ScrollBox children=" .. count .. " parent=" .. tostring(container:GetFullName()))

  -- A valid UObject at this path, or nil. Each call runs in pcall.
  local function FindValid(path)
    local okF, obj = pcall(StaticFindObject, path)
    if not okF or obj == nil then return nil end
    local okV, valid = pcall(function() return obj:IsValid() end)
    if okV and valid == true then return obj end
    return nil
  end

  -- The gradient material for the orange text. Used by the banner font fallback and by the orange text.
  local matName = "/Game/UI/Mat/INST_FontGradient_MainMenu.INST_FontGradient_MainMenu"
  local mat = FindValid(matName)
  local matValid = mat ~= nil
  local matFull = nil
  if matValid then
    local okN, full = pcall(function() return mat:GetFullName() end)
    if okN and full ~= nil then matFull = tostring(full) end
  end

  -- The black-to-transparent banner texture for the mode Borders. Nil when it is not found.
  local bgTexture = FindValid("/Game/UI/Icons/ICON_Border_ModeType.ICON_Border_ModeType")
  local textured = {}   -- Border name -> true when the Border got the banner texture
  local mirrored = {}   -- Border name -> true when the Border got the mirrored banner brush (Modifiers only)
  local faded = {}      -- Border name -> true when the Border got the two-sided fade brush
  local FADED_BORDERS = { ReforgedEndlessModeBorder = true, ReforgedEndlessModifiersBorder = true }
  -- The navy texture with transparent ends (20% at each side). The Mode box uses it for a fade at both ends. Nil when not found.
  local fadeTex = FindValid("/Game/UI/Icons/ICON_Border_WeeklyChallenge.ICON_Border_WeeklyChallenge")

  -- The font of the live banner text (TextBlock_151 in the hub's WidgetTree). Nil when it cannot be read.
  -- The object path of the hub (the part of GetFullName after the class name). Nil when it cannot be read.
  local function HubPath()
    local okP, path = pcall(function()
      local full = tostring(hub:GetFullName())
      local sp = full:find(" ", 1, true)
      if sp == nil then return nil end
      return full:sub(sp + 1)
    end)
    if okP then return path end
    return nil
  end

  local function ReadBannerFont()
    local path = HubPath()
    if path == nil then return nil end
    local banner = FindValid(path .. ".WidgetTree.TextBlock_151")
    if banner == nil then return nil end
    local okR, f = pcall(function()
      local ft = banner.Font
      return { FontObject = ft.FontObject, TypefaceFontName = ft.TypefaceFontName, Size = ft.Size,
        LetterSpacing = ft.LetterSpacing or 0, FontMaterial = ft.FontMaterial }
    end)
    if not okR then return nil end
    return f
  end

  -- The font for the row texts. "banner" reads the live banner. "fallback" uses the Piekos font at size 42.
  -- "none" keeps the menu font (M3). fontSpec is nil for "none".
  local fontSpec, fontSource = nil, "none"
  local bannerFont = ReadBannerFont()
  if bannerFont ~= nil then
    fontSpec, fontSource = bannerFont, "banner"
  else
    local piekos = FindValid("/Game/UI/Fonts/Piekos_OMD-Basic_Font.Piekos_OMD-Basic_Font")
    if piekos ~= nil then
      local okN, fname = pcall(FName, "Default")
      fontSpec = { FontObject = piekos, TypefaceFontName = okN and fname or "Default", Size = 42,
        LetterSpacing = 0, FontMaterial = mat }
      fontSource = "fallback"
    end
  end
  local sizeText = "nil"
  if fontSpec ~= nil and type(fontSpec.Size) == "number" then sizeText = ("%g"):format(fontSpec.Size) end

  -- The stock ENDLESS banner: the text (ScaleBox_116 holds TextBlock_151) and the background (Image_390). Found here,
  -- hidden only when the row is placed (below).
  local bannerPath = HubPath()
  local bannerTextW = bannerPath and FindValid(bannerPath .. ".WidgetTree.ScaleBox_116") or nil
  local bannerBgW = bannerPath and FindValid(bannerPath .. ".WidgetTree.Image_390") or nil

  local textClass = StaticFindObject("/Script/UMG.TextBlock")
  print("[Reforged] endless-mode TextBlock class=" .. tostring(textClass))
  -- StaticConstructObject is the only construct path. The tree's own construct method is not reflected and always raised.
  local okNew, text = Step("construct (StaticConstructObject)", function()
    return StaticConstructObject(textClass, hub.WidgetTree, FName(MODE_BOX_NAME))
  end)
  if not okNew or not text then return end
  modeTextBlock = text
  -- The menu font is kept only when the banner font is not found. Otherwise SetFont sets the font.
  if fontSource == "none" and MenuFontScreen then pcall(MenuFontScreen, "hub", { { text, MODE_BOX_NAME } }) end
  modeTextHub = hub
  ModeRow = {}
  local okRoot, rootName = pcall(function() return hub.WidgetTree.RootWidget:GetFullName() end)
  print("[Reforged] endless-mode root widget=" .. tostring(okRoot and rootName or "unreadable"))

  -- Puts a widget on the hub's root canvas first, at a high Z-order, so it is not under the list. The list's canvas is
  -- the fallback. Returns the slot and whether it is on the root canvas, or nil when neither canvas took the widget.
  local function AddModeWidget(widget)
    local okSlot, slot = Step("add to root canvas", function() return hub.WidgetTree.RootWidget:AddChildToCanvas(widget) end)
    local onRoot = okSlot and slot
    if not onRoot then okSlot, slot = Step("add to canvas", function() return container:AddChildToCanvas(widget) end) end
    if not (okSlot and slot) then return nil, nil end
    Step("place above list", function()
      if onRoot then
        slot:SetPosition({ X = 150, Y = 112 })     -- under BACK, over the mission list's thumbnails (design units)
        slot:SetAutoSize(true)
        Step("z-order", function() slot:SetZOrder(1000) end)
        print("[Reforged] endless-mode text placed on the root canvas at 150,112")
        return
      end
      local okPos, sx, sy = pcall(function()
        local p = scroll.Slot:GetPosition()
        return p.X, p.Y
      end)
      if not okPos then print("[Reforged] endless-mode list position unreadable"); return end
      slot:SetPosition({ X = sx, Y = sy - 60 })
      slot:SetAutoSize(true)
      print(("[Reforged] endless-mode text placed at %.0f,%.0f"):format(sx, sy - 60))
    end)
    print("[Reforged] endless-mode text added above the mission list")
    return slot, onRoot
  end

  -- A Border with padding around one widget. It gets the banner texture when the texture is found and the brush
  -- takes it. Otherwise it is black. Returns nil when the Border cannot be built or filled.
  local function MakeBorder(name, content)
    local okB, border = Step("construct " .. name, function()
      return StaticConstructObject(StaticFindObject("/Script/UMG.Border"), hub.WidgetTree, FName(name))
    end)
    if not (okB and border) then return nil end
    local okTex = false
    if bgTexture ~= nil then
      okTex = Step("texture " .. name, function() border:SetBrushFromTexture(bgTexture) end)
    end
    textured[name] = okTex and true or false
    -- The two-ended fade. The Mode box and the Modifiers box both get it. The fade texture is navy already; the
    -- colour sets its alpha. If the fade brush fails, the banner texture stays with the M5 colour and padding.
    local okFade = false
    if okTex and fadeTex ~= nil and FADED_BORDERS[name] then
      okFade = Step("fade " .. name, function()
        border:SetBrush({ ResourceObject = fadeTex, ImageSize = { X = 1024, Y = 778 }, DrawAs = 3, Tiling = 0, Mirroring = 0,
          TintColor = { SpecifiedColor = { R = 1, G = 1, B = 1, A = 1 }, ColorUseRule = 0 } })
      end)
    end
    faded[name] = okFade and true or false
    -- The Modifiers box mirrors the banner, so its dark side is on the left. It mirrors only when the fade did not
    -- work. If the mirrored brush fails, the unmirrored texture stays and the padding is the unmirrored one.
    local okMirror = false
    if okTex and not okFade and name == "ReforgedEndlessModifiersBorder" then
      okMirror = Step("mirror " .. name, function()
        border:SetBrush({ ResourceObject = bgTexture, ImageSize = { X = 512, Y = 72 }, DrawAs = 3, Tiling = 0, Mirroring = 1,
          TintColor = { SpecifiedColor = { R = 1, G = 1, B = 1, A = 1 }, ColorUseRule = 0 } })
      end)
    end
    mirrored[name] = okMirror and true or false
    local okF = Step("fill " .. name, function()
      if okTex and okFade then
        border:SetBrushColor({ R = 1, G = 1, B = 1, A = 0.8 })
        border:SetPadding({ Left = 64, Top = 4, Right = 64, Bottom = 4 })
      elseif okTex then
        border:SetBrushColor({ R = 1, G = 1, B = 1, A = 1 })
        if okMirror then
          border:SetPadding({ Left = 56, Top = 4, Right = 48, Bottom = 4 })
        else
          border:SetPadding({ Left = 48, Top = 4, Right = 24, Bottom = 4 })
        end
      else
        border:SetBrushColor({ R = 0, G = 0, B = 0, A = 0.6 })
        border:SetPadding({ Left = 16, Top = 8, Right = 16, Bottom = 8 })
      end
      border:SetContent(content)
    end)
    if not okF then return nil end
    return border
  end

  -- A TextBlock for the row. The menu font is set only when the banner font is not found. Returns nil when it cannot
  -- be built.
  local function MakeText(name)
    local okT, tb = Step("construct text " .. name, function()
      return StaticConstructObject(textClass, hub.WidgetTree, FName(name))
    end)
    if not (okT and tb) then return nil end
    if fontSource == "none" and MenuFontScreen then pcall(MenuFontScreen, "hub", { { tb, name } }) end
    return tb
  end

  -- A box in the row: vertically centered, with a gap on the right.
  local function StyleRowSlot(label, slot)
    return Step("row slot " .. label, function()
      slot:SetVerticalAlignment(2)
      slot:SetPadding({ Left = 0, Top = 0, Right = 12, Bottom = 0 })
    end)
  end

  -- The row, left to right: [TEST MODE] [Endless mode] [Modifiers]. It sits left of the stock ENDLESS banner.
  -- Returns true when every step works. Returns the row too, so the caller can take it off its parent.
  local function BuildRow()
    local okRow, row = Step("construct row", function()
      return StaticConstructObject(StaticFindObject("/Script/UMG.HorizontalBox"), hub.WidgetTree, FName("ReforgedEndlessModeRow"))
    end)
    if not (okRow and row) then return false, nil end
    local test = MakeText("ReforgedEndlessTestBox")
    local mods = MakeText("ReforgedEndlessModifiersBox")
    if not (test and mods) then return false, row end
    ModeRow.test, ModeRow.mods = test, mods
    local testBorder = MakeBorder("ReforgedEndlessTestBorder", test)
    if not testBorder then return false, row end
    ModeRow.testBorder = testBorder
    local modsBorder = MakeBorder("ReforgedEndlessModifiersBorder", mods)
    if not modsBorder then return false, row end
    ModeRow.modsBorder = modsBorder
    local modeBorder = MakeBorder("ReforgedEndlessModeBorder", text)
    if not modeBorder then return false, row end
    ModeRow.modeBorder = modeBorder
    -- Order: test, mode, mods. The first added box is the left-most.
    local okT, slotT = Step("row add test", function() return row:AddChildToHorizontalBox(testBorder) end)
    if not (okT and slotT and StyleRowSlot("test", slotT)) then return false, row end
    local okD, slotD = Step("row add mode", function() return row:AddChildToHorizontalBox(modeBorder) end)
    if not (okD and slotD and StyleRowSlot("mode", slotD)) then return false, row end
    local okM, slotM = Step("row add mods", function() return row:AddChildToHorizontalBox(modsBorder) end)
    if not (okM and slotM and StyleRowSlot("mods", slotM)) then return false, row end
    local okR, slotR = Step("row add to root canvas", function() return hub.WidgetTree.RootWidget:AddChildToCanvas(row) end)
    if not (okR and slotR) then return false, row end
    local placed = Step("row place", function()
      slotR:SetAnchors({ Minimum = { X = 1, Y = 0 }, Maximum = { X = 1, Y = 0 } })
      slotR:SetAlignment({ X = 1, Y = 0.5 })
      slotR:SetPosition({ X = -16, Y = 83.54 })
      slotR:SetAutoSize(true)
      slotR:SetZOrder(1000)
    end)
    if not placed then return false, row end
    print("[Reforged] endless-mode row placed right=-16 y=83.54 anchors=1,0 align=1,0.5")
    return true, row
  end

  local function Detach(widget)
    if widget ~= nil then pcall(function() widget:RemoveFromParent() end) end
  end

  -- Collapses one stock banner widget in its own pcall. Returns true when the call worked.
  local function CollapseBanner(w)
    if w == nil then return false end
    local okC = pcall(function() w:SetVisibility(1) end) -- 1 = ESlateVisibility::Collapsed
    return okC and true or false
  end

  local rowOk, rowWidget = BuildRow()
  local modeBorder = ModeRow.modeBorder
  if rowOk then
    ModeRow.row = rowWidget
    -- The row replaces the stock banner, so the banner is hidden. The fallback keeps it.
    ModeRow.bannerText, ModeRow.bannerBg = bannerTextW, bannerBgW
    local hidText = CollapseBanner(bannerTextW)
    local hidBg = CollapseBanner(bannerBgW)
    print(("[Reforged] hub banner hidden text=%s bg=%s"):format(tostring(hidText), tostring(hidBg)))
  else
    -- Fallback: one box at 150,112, as before the row. Take the parts off their parents first.
    print("[Reforged] endless-mode row failed, single box at 150,112")
    Detach(rowWidget)
    Detach(ModeRow.modsBorder)
    Detach(ModeRow.testBorder)
    Detach(modeBorder)
    ModeRow = {}
    if modeBorder == nil then modeBorder = MakeBorder("ReforgedEndlessModeBorder", text) end
  end

  -- Returns "material" or "fallback" or "none". Each box gets its own call.
  -- With a banner or fallback font, SetFont sets the font and its material. Without a material, the color is orange.
  -- With no font found, the menu font keeps its values and takes the gradient material (M3). Without it, the color is orange.
  local function StyleText(tb)
    if fontSpec ~= nil then
      local okSet = Step("row font", function()
        tb:SetFont({ FontObject = fontSpec.FontObject, TypefaceFontName = fontSpec.TypefaceFontName, Size = fontSpec.Size,
          LetterSpacing = fontSpec.LetterSpacing, FontMaterial = fontSpec.FontMaterial })
      end)
      if okSet and fontSpec.FontMaterial ~= nil then return "material" end
    elseif matValid then
      local okF, f = pcall(function()
        local ft = tb.Font
        return { FontObject = ft.FontObject, TypefaceFontName = ft.TypefaceFontName, Size = ft.Size, LetterSpacing = ft.LetterSpacing or 0 }
      end)
      if okF and f then
        local okSet = Step("orange font", function()
          tb:SetFont({ FontObject = f.FontObject, TypefaceFontName = f.TypefaceFontName, Size = f.Size,
            LetterSpacing = f.LetterSpacing, FontMaterial = mat })
        end)
        if okSet then return "material" end
      end
    end
    local okCol = Step("orange color", function()
      tb:SetColorAndOpacity({ SpecifiedColor = { R = 1.0, G = 0.45, B = 0.0, A = 1.0 }, ColorUseRule = 0 })
    end)
    return okCol and "fallback" or "none"
  end

  local onBorder = rowOk
  if not rowOk then
    local slot = nil
    if modeBorder ~= nil then slot = AddModeWidget(modeBorder) end
    onBorder = slot ~= nil
    if slot == nil then AddModeWidget(text) end
  end
  SetModeText(ReadEndlessMode())
  local colorMode = StyleText(text)
  if rowOk then
    StyleText(ModeRow.mods)
    StyleText(ModeRow.test)
  end
  -- The hub PLAY label reads "Play Reforged". Only the label changes; the button action stays.
  local okA, errA = pcall(function() hub.ActionBtn_Text:SetText(FText("Play Reforged")) end)
  print("[Reforged] hub label ActionBtn ok=" .. tostring(okA) .. (okA and "" or (" err=" .. tostring(errA))))
  local bgText = textured["ReforgedEndlessModeBorder"] and "texture" or "black"
  local mirrorText = mirrored["ReforgedEndlessModifiersBorder"] and "true" or "false"
  local fadeText = faded["ReforgedEndlessModeBorder"] and "true" or "false"
  local modsFadeText = faded["ReforgedEndlessModifiersBorder"] and "true" or "false"
  print(("[Reforged] endless-mode style border=%s mat=%s color=%s font=%s size=%s bg=%s mirror=%s fade=%s modsfade=%s"):format(
    tostring(onBorder), tostring(matFull), colorMode, fontSource, sizeText, bgText, mirrorText, fadeText, modsFadeText))
end

-- Play screen watch events. The Endless hub is the Play screen. These hooks only read the game and emit `ui`
-- events. Each body runs in pcall. A failure prints one play-ui line.
do
  local function Null(v) if v == nil then return WatchNull end return v end

  -- Text of an FString or FName. Uses ToString when the value has it; otherwise tostring.
  local function PlayText(v)
    if v == nil then return nil end
    local okS, s = pcall(function() return v:ToString() end)
    if okS and s ~= nil then return tostring(s) end
    return tostring(v)
  end

  -- Level name of the mission the game instance holds (the one the hub selected).
  local function PlayLevel()
    local gi = FindFirstOf("BP_OMDGameInstance_C")
    if not gi then error("BP_OMDGameInstance_C not found") end
    return PlayText(gi:GetCurrentMissionLevelName())
  end

  -- The mission list entries that belong to the Endless hub. Source `scroll`: the valid children of the hub
  -- mission ScrollBox that FindMissionScroll returns. Source `find` (fallback): MissionListEntryProto_UMG_C objects
  -- whose name contains HubScreen. The log line `play-ui entries` names the source. Last printed key: block-local.
  local lastEntriesKey = nil

  -- The valid children of the hub ScrollBox. A child that fails to read or is not valid is skipped.
  local function ScrollChildren(scroll, n)
    local kept = {}
    for i = 0, n - 1 do
      local okC, child = pcall(function() return scroll:GetChildAt(i) end)
      if okC and child ~= nil then
        local okV, valid = pcall(function() return child:IsValid() end)
        if okV and valid == true then kept[#kept + 1] = child end
      end
    end
    return kept
  end

  local function HubEntries()
    local okS, scroll, n = pcall(FindMissionScroll)
    if not okS then scroll, n = nil, 0 end
    local key = "none"
    if scroll ~= nil then
      local okK, scrollName = pcall(function() return scroll:GetFullName() end)
      if okK and type(scrollName) == "string" then key = scrollName end
    end
    local out, source = {}, "none"
    if scroll ~= nil and type(n) == "number" and n > 0 then out = ScrollChildren(scroll, n) end
    if #out > 0 then
      source = "scroll"
    else
      for _, w in ipairs(FindAllOf("MissionListEntryProto_UMG_C") or {}) do
        local okN, name = pcall(function() return w:GetFullName() end)
        if okN and type(name) == "string" and name:find("HubScreen", 1, true) then out[#out + 1] = w end
      end
      if #out > 0 then source = "find" end
    end
    if key ~= lastEntriesKey then
      lastEntriesKey = key
      local first = "none"
      if out[1] ~= nil then
        local okF, fullName = pcall(function() return out[1]:GetFullName() end)
        if okF and fullName ~= nil then first = tostring(fullName) end
      end
      print(("[Reforged] play-ui entries source=%s n=%d first=%s"):format(source, #out, first))
    end
    return out
  end

  local function EntryNumber(entry)
    local ok, n = pcall(function() return entry.MissionNumber end)
    if ok and type(n) == "number" then return n end
    return nil
  end

  local function EntryUnlocked(entry)
    local ok, u = pcall(function() return entry.bIsUnlocked end)
    if ok and type(u) == "boolean" then return u end
    return nil
  end

  -- The Protodata reads were removed after a crash in game (2026-10-18); the level is null.
  local function EntryLevel(entry)
    return nil
  end

  -- Retries like BuildEndlessModeBox (1 s, up to 15 times) while the mission list is empty. Emits once: at the first
  -- non-empty list, or after the 15th retry with count 0. `tries` is the retry count (nil on the first call).
  function PlayUiShown(tries)
    local ok, err = pcall(function()
      local entries, locked = HubEntries(), 0
      if #entries == 0 and (tries or 0) < 15 then
        GameDelay(1000, function() PlayUiShown((tries or 0) + 1) end)
        return
      end
      for _, w in ipairs(entries) do
        if EntryUnlocked(w) == false then locked = locked + 1 end
      end
      WatchEmit("ui", { screen = "play", action = "shown", count = #entries, locked = locked, tries = tries or 0 })
    end)
    if not ok then print("[Reforged] play-ui shown err=" .. tostring(err)) end
  end

  function PlayUiPick()
    local ok, err = pcall(function()
      WatchEmit("ui", { screen = "play", action = "pick", level = Null(PlayLevel()) })
    end)
    if not ok then print("[Reforged] play-ui pick err=" .. tostring(err)) end
  end

  function PlayUiLaunch()
    local ok, err = pcall(function()
      WatchEmit("ui", { screen = "play", action = "launch", level = Null(PlayLevel()), mode = Null(ReadEndlessMode()) })
      -- The Endless difficulty is set on every launch, not only at Play start.
      pcall(SetEndlessDifficulty, "hub-launch")
    end)
    if not ok then print("[Reforged] play-ui launch err=" .. tostring(err)) end
  end

  -- Developer command `play-list` (testing on). One event with every hub entry, sorted by mission number.
  function PlayUiList()
    local ok, err = pcall(function()
      local rows, locked = {}, 0
      for _, entry in ipairs(HubEntries()) do
        local number, unlocked = EntryNumber(entry), EntryUnlocked(entry)
        if unlocked == false then locked = locked + 1 end
        rows[#rows + 1] = { key = number or math.huge, seq = #rows + 1,
          row = WatchList({ Null(number), Null(EntryLevel(entry)), Null(unlocked) }) }
      end
      table.sort(rows, function(a, b)
        if a.key ~= b.key then return a.key < b.key end
        return a.seq < b.seq
      end)
      local maps = {}
      for i, r in ipairs(rows) do maps[i] = r.row end
      WatchEmit("ui", { screen = "play", action = "list", maps = WatchList(maps) })
      print(("[Reforged] play-list count=%d locked=%d"):format(#rows, locked))
    end)
    if not ok then print("[Reforged] play-ui list err=" .. tostring(err)) end
  end
end

local function HookEndlessModeHub()
  -- LoadAsset may only run on the game thread; the hook is registered there too
  ExecuteInGameThread(function()
    LoadAsset("/Game/UI/HUB/HUBScreen_UMG.HubScreen_UMG_C")
    local ok, err = SafeRegisterHook("/Game/UI/HUB/HUBScreen_UMG.HubScreen_UMG_C:Construct", function()
      HookTrace("HubScreen.Construct")
      -- Each call has its own pcall, so a failure in one does not stop the other.
      GameDelay(1500, function() local okB, errB = pcall(BuildEndlessModeBox)
        if not okB then print("[Reforged] endless-mode box err=" .. tostring(errB)) end
        local okU, errU = pcall(PlayUiShown)
        if not okU then print("[Reforged] play-ui shown err=" .. tostring(errU)) end end)
    end)
    print("[Reforged] endless-mode hub hook registered=" .. tostring(ok) .. " " .. tostring(err))
    local okP, errP = SafeRegisterHook("/Game/UI/HUB/HUBScreen_UMG.HubScreen_UMG_C:OnMissionSelected", function() PlayUiPick() end)
    print("[Reforged] play-ui pick hook registered=" .. tostring(okP) .. " " .. tostring(errP))
    local okL, errL = SafeRegisterHook("/Game/UI/HUB/HUBScreen_UMG.HubScreen_UMG_C:Manual_SinglePlayer_LaunchGame", function() PlayUiLaunch() end)
    print("[Reforged] play-ui launch hook registered=" .. tostring(okL) .. " " .. tostring(errL))
  end)
end
HookEndlessModeHub()

-- Start screen. The stock MainMenu_UMG keeps three buttons, Play, Options and Quit (the stock ExitBtn,
-- relabeled). The hooks collapse the other buttons and run the Endless steps after the stock Play action. A UE4SS hook on a Blueprint function runs AFTER
-- the function, so the stock action is not stopped. Section: "Start screen step 4 amended".
-- Buttons and hook paths: the main-menu widgets research. `start-screen off` makes every hook do nothing.
if START_SCREEN == nil then START_SCREEN = true end
-- Wrapped in do ... end: the main chunk has a limit of 200 locals (Lua), and this block adds several.
do
local START_COLLAPSE = { "PatchNotesBtn", "ChangeUserButton", "StoreOfferWIdget_UMG", "News_UMG" }
local CAMPAIGN_SCREEN_GUID = "4D71576E-4A6D-534D-650C-58AA04FBCCE3" -- CampaignScreen (the Endless map list)

-- UE GUID text, 8-4-4-4-12 hex with hyphens (FGuid digits form) -> { A=, B=, C=, D= } as signed int32, the form a
-- struct parameter takes. Each of A to D is 8 hex digits of the 32-digit string, in order.
function GuidFromString(text)
  local s = tostring(text)
  if not s:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$") then return nil end
  local hex = s:gsub("%-", "")
  local a, b, c, d = hex:sub(1, 8), hex:sub(9, 16), hex:sub(17, 24), hex:sub(25, 32)
  local function signed(word)
    local n = tonumber(word, 16)
    if n >= 0x80000000 then n = n - 0x100000000 end
    return n
  end
  return { A = signed(a), B = signed(b), C = signed(c), D = signed(d) }
end

local function StartLog(step, ok, err)
  print("[Reforged] start-play " .. step .. " ok=" .. tostring(ok) .. (ok and "" or (" err=" .. tostring(err))))
  return ok
end

-- Difficulty that Play sets. 3 is the literal the stock ModeSelect Endless button passes to SetCurrentDifficulty.
-- Research commit 96fc314. Mode 1 (WarMage) turns Endless scaling off.
ENDLESS_DIFFICULTY = 3

-- Reads the game difficulty through the difficulty library default object. The getter has an OUT parameter, so the call
-- passes a table: UE4SS fills out.gameDifficulty (or out[1]). Returns a number, or nil when the read fails.
function ReadGameDifficulty()
  local value
  pcall(function()
    local lib = StaticFindObject("/Script/OMD.Default__OMDDifficultyBlueprintLibrary")
    if not lib or not lib:IsValid() then error("OMDDifficultyBlueprintLibrary default object not found") end
    local out = {}
    lib:GetGameDifficulty(out)
    local v = out.gameDifficulty
    if v == nil then v = out[1] end
    value = tonumber(v)
  end)
  return value
end

-- Sets Endless difficulty through the game instance and the difficulty library. Each set runs in its own pcall.
-- `why` names the caller in the log line. Call it after SetCurrentCampaign, which rewrites the difficulty.
function SetEndlessDifficulty(why)
  local okG, errG = pcall(function()
    local gi = FindFirstOf("BP_OMDGameInstance_C")
    if not gi or not gi:IsValid() then error("BP_OMDGameInstance_C not found") end
    gi:SetCurrentDifficulty(ENDLESS_DIFFICULTY)
  end)
  local okL, errL = pcall(function()
    local lib = StaticFindObject("/Script/OMD.Default__OMDDifficultyBlueprintLibrary")
    if not lib or not lib:IsValid() then error("OMDDifficultyBlueprintLibrary default object not found") end
    lib:SetGameDifficulty(ENDLESS_DIFFICULTY)
  end)
  if not okG or not okL then
    print("[Reforged] difficulty set err=" .. tostring(okG and "" or errG) .. " lib-err=" .. tostring(okL and "" or errL))
  end
  print("[Reforged] difficulty set=" .. tostring(ENDLESS_DIFFICULTY) .. " why=" .. tostring(why)
    .. " readback=" .. tostring(ReadGameDifficulty()))
end

-- Developer command `difficulty [n]` (testing on). No argument: print the readback. With n (0-3): set it, then print the readback.
function DifficultyCommand(arg)
  if arg == nil or arg == "" then
    print("[Reforged] difficulty readback=" .. tostring(ReadGameDifficulty()))
    return
  end
  local n = tonumber(arg)
  if not n or n ~= math.floor(n) or n < 0 or n > 3 then
    print("[Reforged] difficulty rejected: use difficulty 0-3, got " .. tostring(arg))
    return
  end
  local ok, err = pcall(function()
    local lib = StaticFindObject("/Script/OMD.Default__OMDDifficultyBlueprintLibrary")
    if not lib or not lib:IsValid() then error("OMDDifficultyBlueprintLibrary default object not found") end
    lib:SetGameDifficulty(n)
  end)
  print("[Reforged] difficulty set=" .. tostring(n) .. " why=command readback=" .. tostring(ReadGameDifficulty())
    .. (ok and "" or (" err=" .. tostring(err))))
end

-- Endless steps after the stock Play action: campaign, difficulty, then the Endless hub (CampaignScreen).
-- Runs on the game thread, 300 ms after the click. Each step logs ok and the error text. A failed step stops the rest.
local function StartPlayNavigate()
  if not START_SCREEN then return end
  local gi, pc, lib
  local ok, err = pcall(function()
    gi = FindFirstOf("BP_OMDGameInstance_C")
    if not gi then error("BP_OMDGameInstance_C not found") end
  end)
  if not StartLog("game-instance", ok, err) then return end
  ok, err = pcall(function()
    pc = FindFirstOf("OMDPlayerController")
    if not pc then error("OMDPlayerController not found") end
  end)
  if not StartLog("player-controller", ok, err) then return end
  ok, err = pcall(function() gi:SetCurrentCampaign(gi.EndlessCampaign) end)
  if not StartLog("set-campaign", ok, err) then return end
  -- The saved value is read for the log only. A failed read gives saved=nil. The set does not depend on it.
  local saved
  pcall(function()
    lib = StaticFindObject("/Script/OMD.Default__OMDSaveGameBlueprintLibrary")
    if not lib or not lib:IsValid() then error("OMDSaveGameBlueprintLibrary default object not found") end
    saved = lib:GetCampaignDifficulty(pc, gi.EndlessCampaign)
  end)
  print("[Reforged] start-play saved=" .. tostring(saved))
  -- Set after the campaign call. SetCurrentCampaign writes the saved difficulty of the campaign.
  SetEndlessDifficulty("start-play")
  ok, err = pcall(function()
    lib = StaticFindObject("/Script/OMD.Default__OMDWidgetBlueprintLibrary")
    if not lib or not lib:IsValid() then error("OMDWidgetBlueprintLibrary default object not found") end
    local guid = GuidFromString(CAMPAIGN_SCREEN_GUID)
    if not guid then error("bad CampaignScreen GUID") end
    lib:NavigateTo(pc, { Guid = guid })
  end)
  StartLog("navigate-campaign-screen", ok, err)
end

-- Construct: after 500 ms, collapse every button and panel except Play, Options and Quit. Quit gets the label "Quit".
-- The Construct hook parameter is not kept. A UE4SS hook parameter is valid only during the hook call (commit 8d12522
-- crashed at boot when the delayed call used it). The delayed call finds the widget again.
local function StartScreenConstruct()
  if not START_SCREEN then return end
  -- The start screen is a menu, so this job runs on any map (AfterAny).
  AfterAny(500, function()
    GameNow(function()
      if not START_SCREEN then return end
      local w = nil
      local okF, found = pcall(FindAllOf, "MainMenu_UMG_C")
      if okF and found then
        for _, cand in ipairs(found) do
          local okV, valid = pcall(function() return cand:IsValid() end)
          if okV and valid then w = cand; break end
        end
      end
      if not w then
        print("[Reforged] start-screen no valid main menu")
        return
      end
      for _, name in ipairs(START_COLLAPSE) do
        local ok, err = pcall(function() w[name]:SetVisibility(1) end) -- 1 = ESlateVisibility::Collapsed
        print("[Reforged] start-screen collapse " .. name .. " ok=" .. tostring(ok) .. (ok and "" or (" err=" .. tostring(err))))
      end
      -- Quit: the stock ExitBtn stays visible and its label reads "Quit". Each call has its own pcall.
      local okV, errV = pcall(function() w.ExitBtn:SetVisibility(0) end) -- 0 = ESlateVisibility::Visible
      local okT, errT = pcall(function() w.TextBlock_117:SetText(FText("Quit")) end)
      local okQ = okV and okT
      local errQ = (not okV and errV) or (not okT and errT) or nil
      print("[Reforged] start-screen label ExitBtn ok=" .. tostring(okQ) .. (okQ and "" or (" err=" .. tostring(errQ))))
      -- Play: the stock PlayBtn label reads "Play Reforged". Only the label changes; the button action stays.
      local okPl, errPl = pcall(function() w.TextBlock_114:SetText(FText("Play Reforged")) end)
      print("[Reforged] start-screen label PlayBtn ok=" .. tostring(okPl) .. (okPl and "" or (" err=" .. tostring(errPl))))
      print("[Reforged] start screen shown")
      WatchEmit("ui", { screen = "start", action = "shown" })
    end)
  end)
end

local function StartPlayPressed()
  if not START_SCREEN then return end
  print("[Reforged] start play pressed")
  WatchEmit("ui", { screen = "start", action = "play" })
  -- Menu job, runs on any map (AfterAny).
  AfterAny(300, function() ExecuteInGameThread(StartPlayNavigate) end)
end

local function StartOptionsPressed()
  if not START_SCREEN then return end
  print("[Reforged] start options pressed")
  WatchEmit("ui", { screen = "start", action = "options" })
end

-- The stock ExitBtn click still runs its own action (QuitGame). This hook only logs the click.
local function StartQuitPressed()
  if not START_SCREEN then return end
  print("[Reforged] start quit pressed")
  WatchEmit("ui", { screen = "start", action = "quit" })
end

local function HookStartScreen()
  ExecuteInGameThread(function()
    local okL, errL = pcall(LoadAsset, "/Game/UI/MainMenu/MainMenu_UMG.MainMenu_UMG_C")
    print("[Reforged] start-screen LoadAsset ok=" .. tostring(okL) .. " " .. tostring(errL))
    local ok1, e1 = SafeRegisterHook("/Game/UI/MainMenu/MainMenu_UMG.MainMenu_UMG_C:Construct", function()
      StartScreenConstruct()
    end)
    print("[Reforged] start-screen construct registered=" .. tostring(ok1) .. " " .. tostring(e1))
    local ok2, e2 = SafeRegisterHook("/Game/UI/MainMenu/MainMenu_UMG.MainMenu_UMG_C:BndEvt__Button_121_K2Node_ComponentBoundEvent_0_OnButtonClickedEvent__DelegateSignature", function()
      StartPlayPressed()
    end)
    print("[Reforged] start-screen play registered=" .. tostring(ok2) .. " " .. tostring(e2))
    local ok3, e3 = SafeRegisterHook("/Game/UI/MainMenu/MainMenu_UMG.MainMenu_UMG_C:BndEvt__OptionsBtn_K2Node_ComponentBoundEvent_3_OnButtonClickedEvent__DelegateSignature", function()
      StartOptionsPressed()
    end)
    print("[Reforged] start-screen options registered=" .. tostring(ok3) .. " " .. tostring(e3))
    local ok4, e4 = SafeRegisterHook("/Game/UI/MainMenu/MainMenu_UMG.MainMenu_UMG_C:BndEvt__ExitBtn_K2Node_ComponentBoundEvent_1_OnButtonClickedEvent__DelegateSignature", function()
      StartQuitPressed()
    end)
    print("[Reforged] start-screen quit registered=" .. tostring(ok4) .. " " .. tostring(e4))
  end)
end
HookStartScreen()
end

-- F6 cycles the Endless mode while the hub is open (route B). Outside the hub the key does nothing.
local okKeyBind = pcall(function()
  -- Not F8: the Cinnamon desktop opens Nemo on F8 (observed 2026-10-18).
  RegisterKeyBind(Key.F6, function()
    -- The key callback runs on another thread. It only sets the flag. The loop below acts on the game thread.
    F6_PENDING = true
  end)
end)
print("[Reforged] endless-mode key bind F6 registered=" .. tostring(okKeyBind))
F6_PENDING = F6_PENDING or false
GameLoop(100, function()
  if not F6_PENDING then return false end
  F6_PENDING = false
  EndlessModeKeyPress(EndlessHubOpen())
  return false
end)

-- F5 toggles the modifier setting of the current mode while the Endless hub is open. Outside the hub it does nothing.
-- The key callback only sets the flag. The loop below runs ModifiersKeyPress on the game thread.
do
  local okModKeyBind = pcall(function()
    RegisterKeyBind(Key.F5, function()
      F5_PENDING = true
    end)
  end)
  print("[Reforged] modifiers key bind F5 registered=" .. tostring(okModKeyBind))
  F5_PENDING = F5_PENDING or false
  GameLoop(100, function()
    if not F5_PENDING then return false end
    F5_PENDING = false
    local okM, errM = pcall(ModifiersKeyPress, EndlessHubOpen())
    if not okM then print("[Reforged] modifiers key err=" .. tostring(errM)) end
    return false
  end)
end

-- F7 moves the Rift to the player before the first combat. Works in every mode and without testing on.
-- In the Endless hub, F7 toggles test mode instead. The hub is open, so the rift move does not run.
-- The key callback only sets the flag. The loop below runs RiftMoveKey on the game thread.
do
  local okRiftKeyBind = pcall(function()
    RegisterKeyBind(Key.F7, function()
      F7_PENDING = true
    end)
  end)
  print("[Reforged] rift-move key bind F7 registered=" .. tostring(okRiftKeyBind))
  F7_PENDING = F7_PENDING or false
  GameLoop(100, function()
    if not F7_PENDING then return false end
    F7_PENDING = false
    if EndlessHubOpen() then
      local okT, errT = pcall(TestModeSet, not TEST_MODE, "hub-key")
      if not okT then print("[Reforged] test-mode toggle err=" .. tostring(errT)) end
    else
      pcall(RiftMoveKey)
    end
    return false
  end)
end

-- LB + RB on a controller moves the Rift. Same limits as F7: before the first combat, on the ground, not in the
-- Endless hub (LB and RB turn the hub pages). lbAt and rbAt hold the time each shoulder went down (nil when up).
-- The move fires when both are down within 0.3 s of each other, once per hold. Both must come up before it fires again.
-- Runs in every mode. Globals only. Every game call is in pcall. LB and RB are also the stock loadout keys.
PAD_COMBO = PAD_COMBO or { lbAt = nil, rbAt = nil, fired = false }
function PadComboStep(nowSec)
  local now = nowSec or os.clock()
  local okH, hubOpen = pcall(EndlessHubOpen)
  if okH and hubOpen == true then
    PAD_COMBO.lbAt, PAD_COMBO.rbAt, PAD_COMBO.fired = nil, nil, false
    return
  end
  local okF, pc = pcall(function() return FindFirstOf("OMDPlayerController") end)
  if not okF or not pc then return end
  local okV, valid = pcall(function() return pc:IsValid() == true end)
  if not okV or valid ~= true then return end
  -- A failed read counts as up.
  local okL, lbRes = PadKeyDown(pc, "Gamepad_LeftShoulder")
  local lbDown = okL and lbRes == true
  local okR, rbRes = PadKeyDown(pc, "Gamepad_RightShoulder")
  local rbDown = okR and rbRes == true
  if lbDown then
    if PAD_COMBO.lbAt == nil then PAD_COMBO.lbAt = now end
  else
    PAD_COMBO.lbAt = nil
  end
  if rbDown then
    if PAD_COMBO.rbAt == nil then PAD_COMBO.rbAt = now end
  else
    PAD_COMBO.rbAt = nil
  end
  if lbDown and rbDown and PAD_COMBO.fired ~= true and math.abs(PAD_COMBO.lbAt - PAD_COMBO.rbAt) <= 0.3 then
    PAD_COMBO.fired = true
    print("[Reforged] pad-combo LB+RB -> rift-move")
    pcall(RiftMoveKey, "pad")
  end
  if not lbDown and not rbDown then PAD_COMBO.fired = false end
end

GameLoop(100, function() pcall(PadComboStep); return false end)

-- Score uploads are blocked (#102). The mission score write and the best-score fields run only when game integrity is
-- above 0.5. Integrity 0 blocks them. Lifetime stats and achievements are not blocked. There is no setting to turn it off.
-- Globals, not locals: this chunk is near the 200-local limit.
SCORE_BLOCK = { started = false }

function ScoreBlockInstance()
  local gi
  pcall(function() gi = FindFirstOf("BP_OMDGameInstance_C") end)
  local okV, validV = pcall(function() return gi ~= nil and gi:IsValid() end)
  if okV and validV then return gi end
  gi = nil
  pcall(function() gi = FindFirstOf("OMDGameInstance") end)
  okV, validV = pcall(function() return gi ~= nil and gi:IsValid() end)
  if okV and validV then return gi end
  return nil
end

-- Sets game integrity to 0 and reads it back on the game thread. Prints and emits score-block on every call.
-- Returns true when the readback is 0.
function NoScoreUpload(why)
  local gi = ScoreBlockInstance()
  local ok, integ, err = false, nil, nil
  if not gi then
    err = "game instance not found"
  else
    local okSet, setErr = pcall(function() gi:SetGameIntegrity(0.0) end)
    local okGet, got = pcall(function() return gi:GetGameIntegrity() end)
    if okGet then integ = got end
    if not okSet then err = setErr elseif not okGet then err = got end
    ok = okSet and okGet and type(integ) == "number" and integ == 0
  end
  local tail = " integrity=" .. tostring(integ) .. " ok=" .. tostring(ok)
  if err ~= nil then tail = tail .. " err=" .. tostring(err) end
  -- The startup retry prints and emits only when its result changes. Map-ready and other calls always print.
  if why == "start" then
    if tail == SCORE_BLOCK.lastStart then return ok end
    SCORE_BLOCK.lastStart = tail
  end
  print("[Reforged] score-upload blocked why=" .. tostring(why) .. tail)
  WatchEmit("score-block", { why = why, integrity = (integ == nil) and WatchNull or integ, ok = ok })
  return ok
end

-- Startup: retry on the game-thread loop until the block applies once. No line is printed while the game instance is missing.
-- #70: the loop gives up after 30 tries with an instance present. Map ready still calls NoScoreUpload.
GameLoop(2000, function()
  if SCORE_BLOCK.started or SCORE_BLOCK.gaveUp then return true end
  if not ScoreBlockInstance() then return false end
  SCORE_BLOCK.startTries = (SCORE_BLOCK.startTries or 0) + 1
  if NoScoreUpload("start") then
    SCORE_BLOCK.started = true
    return true
  end
  if SCORE_BLOCK.startTries >= 30 then
    SCORE_BLOCK.gaveUp = true
    print("[Reforged] score-upload startup gave up tries=" .. tostring(SCORE_BLOCK.startTries))
    return true
  end
  return false
end)

-- Map-ready work runs once for each level. The key is the coordinator address. "unknown" is the key when the
-- address cannot be read. A nil key means no coordinator was seen since the last reset (menus), so the next level counts as new.
-- MAP_READY.queued keeps one map-ready callback queued at a time (set on the loop thread).
local MAP_READY = { mapKey = nil, settingsKey = nil, queued = false, lastPrintedKey = nil }

local function MapKey(c)
  local ok, addr = pcall(function() return c:GetAddress() end)
  if ok and addr ~= nil then return tostring(addr) end
  return "unknown"
end

-- The map-ready print and WatchMapReady run once for each map key. Both map-ready places call this.
-- Returns true when the key was not handled yet, and marks it handled. The menus reset the key (MapReadyTick).
function MAP_READY.claim(c)
  local key = MapKey(c)
  if key == MAP_READY.lastPrintedKey then return false end
  MAP_READY.lastPrintedKey = key
  return true
end

-- Applies the Endless settings once for each coordinator address. Both map-ready places call it, so it dedupes them.
local function ApplyMapSettings(c)
  local key = MapKey(c)
  if key == MAP_READY.settingsKey then return false end
  MAP_READY.settingsKey = key
  pcall(ApplySettingsForMode, ReadEndlessMode())
  return true
end

do
  -- Map-ready work for one coordinator. Runs on the game thread.
  local function MapReadyFor(c)
    -- REFORGED.ready stays false until this map's Reforged reset below ends. No round is built in between.
    REFORGED.ready = false
    autoTestMapReady = true
    HOOK_TRACE = {}
    ApplyEndlessMode()
    AnchorNewMap()
    ApplyMapSettings(c)
    PlayerPathReset()
    print("[Reforged] map-ready: breaks-off deferred 15 s so the level can settle")
    if TESTING then After(15000, function() BreaksOff() end) end
    local gi
    pcall(function() gi = FindFirstOf("BP_OMDGameInstance_C") end)
    if not gi or not gi:IsValid() then
      pcall(function() gi = FindFirstOf("OMDGameInstance") end)
    end
    local missionName = "?"
    if gi and gi:IsValid() then
      pcall(function() missionName = gi:GetCurrentMissionLevelName() end)
    end
    -- A call cut off by a map change must not defer restores on the next load.
    DOOR_PENDING = {}
    -- Nearest path points are per map. A new map starts with no cached point.
    CSPAWN_POINT_CACHE = {}
    -- The swap counters are not reset here. Map ready runs after the native build, so a reset hid the swaps.
    QBLOCK.saved = nil
    TICK_HOLD = false
    TICK_HOLD_AUTO_ON = false
    TICK_HOLD_UNTIL = 0
    PACE_QUEUE = {}
    PACE.endNoted = nil -- the pace stop line is once per match (#103 F2)
    -- Held door calls belong to the previous map. Release would run them on this map.
    local droppedHeld = #HOARD_HELD
    HOARD_HELD = {}
    if droppedHeld > 0 then
      print(string.format("[Reforged] map-ready: dropped %d held spawn calls from the previous map", droppedHeld))
    end
    PACE.lastCall = 0
    PACE.bypass = false
    REFORGED_GAP_MULT = 1
    REFORGED = { round = 0, lastBuild = nil, seed = os.time(), last = nil, inBuild = nil, doorStart = 0, waitAt = nil, ready = false, level = nil }
    REFORGED_STOCK.fellBack = {} -- The stock fallback line prints once per round number and map
    -- The level name sets the map bias of each plan. nil = no bias.
    do
      local okLv, lv = pcall(ReforgedMapLevel)
      if okLv and type(lv) == "string" then REFORGED.level = lv end
      print("[Reforged] map-ready level=" .. tostring(REFORGED.level))
    end
    REFORGED_BOSSES_LIVE = {}
    REFORGED_BEARERS = {}
    pcall(ReforgedBreakReset)
    pcall(ReforgedRulesMapReset)
    pcall(CurveMapReset)
    pcall(ClassicModMapReset)
    REFORGED.ready = true
    if MAP_READY.claim(c) then
      pcall(NoScoreUpload, "map-ready")
      WatchMapReady(missionName)
      print("[Reforged] auto-test map ready mission-level=" .. tostring(missionName) .. " " .. population(c))
    end
  end

  -- Polled every 2000 ms. A coordinator with a new address starts the map-ready work again.
  local function MapReadyTick()
    if MAP_READY.queued then return end
    MAP_READY.queued = true
    ExecuteInGameThread(function()
      MAP_READY.queued = false
      local c = coordinator()
      if not c then
        -- Fallback: without the LoadMap hook, the first pass with no coordinator after a map does the map-leave reset.
        if MAP_READY.mapKey ~= nil and MAP_LEAVE_HOOKED ~= true and ReforgedMapLeave then pcall(ReforgedMapLeave, "no-coordinator") end
        MAP_READY.mapKey, MAP_READY.settingsKey, MAP_READY.lastPrintedKey = nil, nil, nil
        return
      end
      local key = MapKey(c)
      if key == MAP_READY.mapKey then return end
      MAP_READY.mapKey = key
      MapReadyFor(c)
    end)
  end
  MapReadyTickForTest = MapReadyTick -- the offline test calls this alias; the game does not use it
  GameLoop(2000, function()
    MapReadyTick()
    return false
  end)
end

local function GameStateBreak()
  local ok, gs = pcall(FindFirstOf, "OMDGameState")
  if ok and gs and gs:IsValid() then
    local okB, active = pcall(function() return gs.bIsGoBreakActive end)
    return tostring(okB and active or "?")
  end
  return "no-gamestate"
end

local function DifficultyManager()
  local ok, dm = pcall(FindFirstOf, "OMDDifficultyManager")
  if ok and dm and dm:IsValid() then return dm end
  return nil
end

local function BreaksRead()
  ExecuteInGameThread(function()
    local dm = DifficultyManager()
    if not dm then print("[Reforged] breaks: no difficulty manager"); return end
    print(string.format("[Reforged] breaks: EndlessIterationNoGoBreaks=%s EndlessTimedBreakReductionPerIteration=%s goBreakCalls=%d hooked=%s bIsGoBreakActive=%s",
      tostring(dm.EndlessIterationNoGoBreaks), tostring(dm.EndlessTimedBreakReductionPerIteration), goBreakCalls, tostring(goBreakHooked), GameStateBreak()))
  end)
end

BreaksOff = function()
  -- Reforged builds each round at a Go Break (HoardReleased reads bIsGoBreakActive). Writing 0 here would turn later breaks timed.
  if QueueBlockMode() == "reforged" then
    print("[Reforged] breaks-off skipped: Reforged keeps Go Breaks (rounds start at G)")
    return
  end
  ExecuteInGameThread(function()
    print("[Reforged] breaks-off step 1: hook go-breaks")
    HookGoBreaks()
    print("[Reforged] breaks-off step 2: find difficulty manager")
    local dm = DifficultyManager()
    if not dm then print("[Reforged] breaks-off: no difficulty manager"); return end
    local before = dm.EndlessIterationNoGoBreaks
    if DM_STOCK.EndlessIterationNoGoBreaks == nil and before ~= 0 then DM_STOCK.EndlessIterationNoGoBreaks = before end
    print("[Reforged] breaks-off step 3: write EndlessIterationNoGoBreaks, was " .. tostring(before))
    -- 0, not 999: the native rule turns a break timed when iteration >= this value.
    -- 999 never fires, so every break stays a Go Break.
    local ok, err = pcall(function() dm.EndlessIterationNoGoBreaks = 0 end)
    print(string.format("[Reforged] breaks-off: EndlessIterationNoGoBreaks %s -> 0 set=%s readback=%s err=%s",
      tostring(before), tostring(ok), tostring(dm.EndlessIterationNoGoBreaks), tostring(err)))
  end)
end

-- Break control. Reforged only.
--   wait:  stock Go Break. G starts the round.
--   auto:  Go Break. SetReady() after `seconds` if G was not pressed (rounds 2 and on).
--   timed: the break after each round is the native 3 s timed break. EndlessIterationNoGoBreaks is 0 in combat;
--          it is restored once a break has started. A Go Break in timed mode (round 2 and on) gets SetReady after 3 s.
-- Round 1 of a map always waits for G, in every mode. ReforgedBreakOverride(mode) sets the mode for the next break only.
-- brk is the open break: { kind, round, mode, seconds, autoAt, autoFired }. Written only in Reforged.
REFORGED_BREAK = { mode = "wait", seconds = 30, override = nil, brk = nil, written = false, stock = nil }
-- Break order. useHook: the TimedBreak hook may start the hold. timedHook: the hook registered. watch: "go" or "timed"
-- (a fast check runs until watchUntil). gs: the cached game state. offset: rounds the stock order is behind (a chained round). chain: a round chain is waiting.
BREAK_ORDER = { useHook = true, timedHook = false, watch = nil, watchUntil = 0, gs = nil, offset = 0, chain = false }

-- Reads the two break flags. Returns goBreak, timed (booleans), or nil, nil when a read fails.
function ReforgedBreakFlags()
  local okG, gs = pcall(FindFirstOf, "OMDGameState")
  if not okG or not gs then return nil, nil end
  local okV, valid = pcall(function() return gs:IsValid() end)
  if not okV or valid ~= true then return nil, nil end
  local okB, goB = pcall(function() return gs.bIsGoBreakActive end)
  local okT, timed = pcall(function() return gs.bIsTimedBreakActive end)
  if not okB or not okT or type(goB) ~= "boolean" or type(timed) ~= "boolean" then return nil, nil end
  return goB, timed
end

-- True when a timed break is active. Used by the round trigger (ReforgedStep).
function ReforgedTimedNow()
  local _, timed = ReforgedBreakFlags()
  return timed == true
end

-- True in Reforged while a timed break is active. TickHoldAutoStep and PaceStep wait for its countdown.
-- Manual and Classic return false. A failed read returns false, so the normal rule applies.
function ReforgedTimedWait()
  if QueueBlockMode() ~= "reforged" then return false end
  return ReforgedTimedNow()
end

-- The mode of the next break: the one-break override, else the setting.
function ReforgedBreakNext()
  return REFORGED_BREAK.override or REFORGED_BREAK.mode
end

-- Sets the mode for the next break only. Other values are ignored.
function ReforgedBreakOverride(mode)
  if mode == "wait" or mode == "auto" or mode == "timed" then
    REFORGED_BREAK.override = mode
  else
    REFORGED_BREAK.override = nil
  end
end

-- Writes the stock value back to EndlessIterationNoGoBreaks. A missing manager keeps the flag, so the next pass retries.
function ReforgedBreakRestore(why)
  local B = REFORGED_BREAK
  local dm = DifficultyManager()
  if not dm then return end
  local ok, err = pcall(function() dm.EndlessIterationNoGoBreaks = B.stock end)
  print(string.format("[Reforged] break restore EndlessIterationNoGoBreaks=%s (%s) set=%s err=%s", tostring(B.stock), why, tostring(ok), tostring(err)))
  B.written, B.stock = false, nil
end

-- Timed mode, one pass. In combat, with a round built and the next break timed, the field is 0 so the next break is timed.
-- A break in progress restores the stock value. The stock value is read once, before the first write.
function ReforgedBreakTimedSync(inBreak)
  local B = REFORGED_BREAK
  local wantZero = (not inBreak) and REFORGED.round >= 1 and ReforgedBreakNext() == "timed"
  if not wantZero then
    if B.written then ReforgedBreakRestore(inBreak and "break started" or "not timed") end
    return
  end
  local dm = DifficultyManager()
  if not dm then return end
  local okR, cur = pcall(function() return dm.EndlessIterationNoGoBreaks end)
  if not okR or type(cur) ~= "number" or cur == 0 then return end
  if not B.written then B.stock = cur end
  local ok, err = pcall(function() dm.EndlessIterationNoGoBreaks = 0 end)
  if ok then B.written = true end
  print(string.format("[Reforged] break timed: EndlessIterationNoGoBreaks %s -> 0 round=%s set=%s err=%s",
    tostring(cur), tostring(REFORGED.round), tostring(ok), tostring(err)))
end

-- Calls SetReady on the player controller (the G path without the key). Returns true when the call ran.
function ReforgedBreakSetReady()
  local okP, pc = pcall(FindFirstOf, "OMDPlayerController")
  if not okP or not pc then print("[Reforged] break auto: no player controller, not ready"); return false end
  local okV, valid = pcall(function() return pc:IsValid() end)
  if not okV or valid ~= true then print("[Reforged] break auto: player controller not valid, not ready"); return false end
  local ok, err = pcall(function() pc:SetReady() end)
  print(string.format("[Reforged] break auto: SetReady set=%s err=%s", tostring(ok), tostring(err)))
  return ok
end

-- One pass of break control. Called from the hoard release loop after ReforgedStep. One break is tracked at a time.
-- A break starts when bIsGoBreakActive or bIsTimedBreakActive goes true, and ends when both are false.
-- The `break` watch event is emitted once, at the end, with startedBy (auto, timed or player).
-- A kind change (timed to go or back) closes the tracked break and opens the other kind in the same pass.
function ReforgedBreakStep()
  if QueueBlockMode() ~= "reforged" then return end
  local goB, timed = ReforgedBreakFlags()
  if goB == nil then return end
  local B = REFORGED_BREAK
  local open = goB or timed
  local kindNow = timed and "timed" or "go"
  if B.brk ~= nil and open and kindNow ~= B.brk.kind then
    ReforgedBreakClose(B.brk)
    B.brk = nil
  end
  if B.brk == nil and open then
    ReforgedBreakOpen(kindNow)
  elseif B.brk ~= nil then
    local brk = B.brk
    if open then
      if brk.autoAt ~= nil and not brk.autoFired and goB and os.time() >= brk.autoAt then
        brk.autoFired = ReforgedBreakSetReady()
      end
    else
      ReforgedBreakClose(brk)
      B.brk = nil
      -- A Go Break closed: the fast check looks for the countdown of the next break.
      if brk.kind == "go" and REFORGED.round >= 1 then
        BREAK_ORDER.watch = "go"
        BREAK_ORDER.watchUntil = os.time() + 8
      end
    end
  end
  ReforgedBreakTimedSync(open)
end

-- Emits the `break` event and the break end line for a tracked break. expected and ok are set by the order check.
function ReforgedBreakClose(brk)
  local startedBy = brk.autoFired and (brk.mode == "timed" and "auto-timed" or "auto") or (brk.kind == "timed" and "timed" or "player")
  local fields = { round = brk.round, mode = brk.mode, kind = brk.kind, seconds = brk.seconds, startedBy = startedBy }
  fields.expected = brk.expected
  fields.ok = brk.ok
  WatchEmit("break", fields)
  print(string.format("[Reforged] break end kind=%s round=%s startedBy=%s", brk.kind, tostring(brk.round), startedBy))
end

-- Opens a tracked break of kind "timed" or "go". Used at a break start and at a kind change.
function ReforgedBreakOpen(kind)
  local B = REFORGED_BREAK
  local round = REFORGED.round
  local mode = ReforgedBreakNext()
  B.override = nil -- a one-break override is used by this break
  if round < 2 then mode = "wait" end -- round 1 of a map always waits for G
  B.brk = { kind = kind, round = round, mode = mode, seconds = B.seconds, autoAt = nil, autoFired = false }
  if kind == "go" and mode == "auto" then B.brk.autoAt = os.time() + B.seconds end
  -- Fallback: the native timed rule does not fire in round 1 with the native spawns blocked, so a Go Break
  -- in timed mode (round 2 and on) gets SetReady after 3 s, as auto does.
  if kind == "go" and mode == "timed" and round >= 2 then
    B.brk.autoAt = os.time() + 3
    print("[Reforged] timed fallback: Go Break, starting the round in 3 s")
  end
  print(string.format("[Reforged] break start kind=%s round=%s mode=%s seconds=%s", kind, tostring(round), mode, tostring(B.seconds)))
  if kind == "timed" then print("[Reforged] timed break: hold and pace wait for the countdown") end
  ReforgedBreakOrderCheck(B.brk)
  -- Fast check: every timed break watches its countdown end. The TimedBreak hook is an extra trigger.
  local W = BREAK_ORDER
  if kind == "timed" then
    W.watch = "timed"
    W.watchUntil = os.time() + (ReforgedTimerNow() or 10) + 5
  end
end

-- Map ready: the break state starts again. A stock value still held by a timed write is restored first.
function ReforgedBreakReset()
  local B = REFORGED_BREAK
  if B.written then ReforgedBreakRestore("map ready") end
  B.written, B.stock, B.brk, B.override = false, nil, nil, nil
  BREAK_ORDER.watch, BREAK_ORDER.gs, BREAK_ORDER.offset, BREAK_ORDER.chain = nil, nil, 0, false
  -- Break gate: Reforged loads the DLL once and closes the gate at map ready. Other modes only release a blocked gate.
  if QueueBlockMode() == "reforged" then
    BreakGateLoad()
    print(string.format("[Reforged] break-gate ready patched=%s err=%s", tostring(BREAK_GATE.patched), tostring(BREAK_GATE.err)))
    BreakGateSet(false, "map-ready")
  elseif BREAK_GATE.blocked == true then
    BreakGateSet(false, "map-ready")
  end
end

-- break-mode: status, wait|auto|timed, seconds <5-300>, next <wait|auto|timed> (the next break only).
function ReforgedBreakCommand(arg1, arg2)
  local B = REFORGED_BREAK
  local modes = { wait = true, auto = true, timed = true }
  if arg1 == nil or arg1 == "" then
    print(string.format("[Reforged] break-mode mode=%s seconds=%s next=%s open=%s round=%s", tostring(B.mode), tostring(B.seconds),
      tostring(ReforgedBreakNext()), tostring(B.brk ~= nil), tostring(REFORGED.round)))
    return
  end
  if modes[arg1] then
    B.mode = arg1
    print("[Reforged] break-mode=" .. arg1)
    return
  end
  if arg1 == "seconds" then
    local n = (arg2 ~= nil and arg2:match("^%d+$")) and tonumber(arg2) or nil
    if n == nil or n < 5 or n > 300 then
      print("[Reforged] command rejected: break-mode seconds needs a whole number from 5 to 300")
      return
    end
    B.seconds = n
    print("[Reforged] break-mode seconds=" .. tostring(n))
    return
  end
  if arg1 == "next" and modes[arg2 or ""] then
    B.override = arg2
    print("[Reforged] break-mode next=" .. arg2 .. " (the next break only)")
    return
  end
  print("[Reforged] command rejected: use break-mode, break-mode wait|auto|timed, break-mode seconds <5-300>, break-mode next <wait|auto|timed>")
end

-- The stock break of round r in a map. Returns kind, seconds, w, I. kind is "unknown" (seconds 0, w and I nil)
-- when the stock table, the map or r is missing. noGo nil = 2. reduction nil = 0.
function ReforgedBreakExpected(level, r, noGo, reduction)
  local lib = REFORGED_STOCK.lib
  if lib == nil or type(lib.breaks) ~= "table" or level == nil or type(r) ~= "number" or r < 1 then return "unknown", 0, nil, nil end
  local b = lib.breaks[level]
  if b == nil then return "unknown", 0, nil, nil end
  local M = b.M
  local w = (r - 1) % M + 1
  local I = (r - 1) // M
  local entry = b.waves[w]
  if entry == nil then return "unknown", 0, nil, nil end
  local kind = entry[1]
  if kind == "go" then
    if I >= (noGo or 2) then return "timed", 3, w, I end
    return "go", 0, w, I
  elseif kind == "timed" then
    return "timed", math.max(entry[2] - I * (reduction or 0), 3), w, I
  end
  return "none", 0, w, I
end

-- The stock break of round r with the live settings. noGo is 0 when the next break is timed.
function ReforgedBreakExpectedNext(r)
  local noGo, reduction = 2, 0
  if ReforgedBreakNext() == "timed" then
    noGo = 0
  else
    local okN, n = pcall(function() return DifficultyManager().EndlessIterationNoGoBreaks end)
    if okN and type(n) == "number" then noGo = n end
  end
  local okR, red = pcall(function() return DifficultyManager().EndlessTimedBreakReductionPerIteration end)
  if okR and type(red) == "number" then reduction = red end
  return ReforgedBreakExpected(REFORGED.level, r, noGo, reduction)
end

-- The game state for the break order. BREAK_ORDER.gs is used while it is valid. nil when none is found.
function ReforgedBreakGS()
  local cached = BREAK_ORDER.gs
  if cached ~= nil then
    local okV, valid = pcall(function() return cached:IsValid() end)
    if okV and valid == true then return cached end
  end
  BREAK_ORDER.gs = nil
  local okF, found = pcall(FindFirstOf, "OMDGameState")
  if not okF or not found then return nil end
  local okV, valid = pcall(function() return found:IsValid() end)
  if not okV or valid ~= true then return nil end
  BREAK_ORDER.gs = found
  return found
end

-- OnslaughtTimer as a number, or nil when the read fails.
function ReforgedTimerNow()
  local okT, t = pcall(function() return ReforgedBreakGS().OnslaughtTimer end)
  if okT and type(t) == "number" then return t end
  return nil
end

-- The order check at a break start. The break for round n is the one after round n-1, so it reads
-- ReforgedBreakExpectedNext(n-1). Sets brk.expected and brk.ok (nil when the stock is unknown) and prints the line.
function ReforgedBreakOrderCheck(brk)
  local n = REFORGED.round
  local expected, w, I
  if n <= 1 then
    expected, w, I = "go", 0, 0
  else
    local kindPrev, secs
    kindPrev, secs, w, I = ReforgedBreakExpectedNext(n - 1)
    expected = kindPrev
  end
  local seen = brk.kind
  local okW, wave = pcall(function() return ReforgedBreakGS().CurrentWave end)
  if not okW or type(wave) ~= "number" then wave = nil end
  local expectedWave = n - BREAK_ORDER.offset
  if REFORGED.round < 1 then expectedWave = 1 end -- the map-start Go Break is wave 1
  local ok = nil
  if expected ~= "unknown" then ok = (expected == seen) and (wave == nil or wave == expectedWave) end
  brk.expected, brk.ok = expected, ok
  print(string.format("[Reforged] break order round=%s w=%s I=%s expected=%s seen=%s wave=%s expectedWave=%s ok=%s",
    tostring(n), tostring(w), tostring(I), tostring(expected), tostring(seen), tostring(wave or "?"), tostring(expectedWave), tostring(ok)))
end

-- The fast check, every 50 ms. It runs only while a watch is set. The hold starts when the countdown ends.
function ReforgedBreakFastStep()
  local W = BREAK_ORDER
  if W.watch == nil or QueueBlockMode() ~= "reforged" then return end
  if os.time() > W.watchUntil then
    print(string.format("[Reforged] break order fast check timed out watch=%s", tostring(W.watch)))
    W.watch = nil
    return
  end
  local gs = ReforgedBreakGS()
  if gs == nil then return end
  local okR, goB, timed, timer = pcall(function() return gs.bIsGoBreakActive, gs.bIsTimedBreakActive, gs.OnslaughtTimer end)
  if not okR or type(timer) ~= "number" then return end
  local via = nil
  if W.watch == "go" and goB == false and timer <= 0.2 then
    via = "fast-check"
  elseif W.watch == "timed" then
    if timed == true and timer <= 0.2 then
      via = "fast-check-timed"
    elseif timed == false then
      via = "fast-check-timed-late" -- the countdown ended between two samples
    end
  end
  if via == nil then return end
  local held, why = ReforgedBreakHoldArm(via)
  if held ~= true then
    print(string.format("[Reforged] round hold at countdown end not set via=%s reason=%s round=%s", via, tostring(why), tostring(REFORGED.round)))
    W.watch = nil
  end
end

-- SetTimedBreakActive fires TimedBreak on each change: true when a timed break starts, false when its countdown ends. The false call starts the hold. Registered once at load.
function ReforgedHookTimedBreak()
  local ok, res = SafeRegisterHook("/Script/OMD.OMDGameState:TimedBreak", function(self, active)
    local value = active
    if type(value) ~= "boolean" then
      local okV, got = pcall(function() return active:get() end)
      if okV then value = got end
    end
    if QueueBlockMode() == "reforged" then
      print(string.format("[Reforged] TimedBreak event active=%s round=%s useHook=%s", tostring(value), tostring(REFORGED.round), BREAK_ORDER.useHook == true and "on" or "off"))
    end
    if value == false and BREAK_ORDER.useHook == true then
      local okA, held, why = pcall(ReforgedBreakHoldArm, "timed-event")
      if okA and held ~= true then
        print(string.format("[Reforged] round hold at countdown end not set via=timed-event reason=%s round=%s", tostring(why), tostring(REFORGED.round)))
      end
    end
  end)
  BREAK_ORDER.timedHook = (ok == true and res ~= false)
  print(string.format("[Reforged] TimedBreak hook registered=%s %s", tostring(BREAK_ORDER.timedHook), tostring(res)))
end

-- break-order: status, or hook on|off.
function ReforgedBreakOrderCommand(arg1, arg2)
  local W = BREAK_ORDER
  if arg1 == nil or arg1 == "" then
    local kind, seconds = ReforgedBreakExpectedNext(REFORGED.round)
    print(string.format("[Reforged] break-order hook=%s registered=%s offset=%s chain=%s watch=%s next=%s seconds=%s round=%s level=%s",
      W.useHook == true and "on" or "off", tostring(W.timedHook == true), tostring(W.offset), tostring(W.chain == true),
      tostring(W.watch or "-"), tostring(kind), tostring(seconds), tostring(REFORGED.round), tostring(REFORGED.level or "?")))
    return
  end
  if arg1 == "hook" and (arg2 == "on" or arg2 == "off") then
    W.useHook = (arg2 == "on")
    print("[Reforged] break-order hook=" .. arg2)
    return
  end
  print("[Reforged] command rejected: break-order takes no argument, or hook on|off")
end

-- Break gate. reforged_gate.dll beside this file swaps the stock break run for a gate: while blocked, no break
-- starts and the wave does not end. Each export is a Lua C function that returns its argument for true and nothing for nil.
BREAK_GATE = { loaded = false, patched = false, err = nil, fns = {}, use = true, blocked = false }
function BreakGateLoad()
  local G = BREAK_GATE
  if G.loaded then return G.patched end
  local cmdPath = WAVE_COMMAND_PATH
  local win64Dir = cmdPath and cmdPath:match("^(.*)/Mods/Reforged/director%.cmd$")
  if not win64Dir then G.err = "no Win64 path"; return false end
  if type(package) ~= "table" or type(package.loadlib) ~= "function" then G.err = "no package.loadlib"; return false end
  local path = win64Dir .. "/ue4ss/Mods/Reforged/Scripts/reforged_gate.dll"
  for _, name in ipairs({ "reforged_gate_init", "reforged_gate_block", "reforged_gate_unblock", "reforged_gate_blocked", "reforged_gate_hits" }) do
    local fn, err = package.loadlib(path, name)
    if type(fn) ~= "function" then G.err = tostring(name) .. ": " .. tostring(err); return false end
    G.fns[name] = fn
  end
  G.loaded = true
  local okI, res = pcall(G.fns.reforged_gate_init, true)
  G.patched = okI and res == true
  if not okI then G.err = tostring(res) elseif not G.patched then G.err = "slot or prologue check failed (see reforged_gate.log)" end
  return G.patched
end
function BreakGateCall(name)
  local fn = BREAK_GATE.fns[name]
  if fn == nil then return nil end
  local ok, res = pcall(fn, true)
  return ok and res == true
end
-- True when the gate replaces the tick hold: Reforged, the DLL patched, and the gate switched on (break-gate on|off).
function BreakGateActive()
  return QueueBlockMode() == "reforged" and BREAK_GATE.patched == true and BREAK_GATE.use ~= false
end
-- Blocks (on = true) or opens the gate. Does nothing when not patched or when the state does not change.
function BreakGateSet(on, why)
  local G = BREAK_GATE
  if G.patched ~= true then return end
  on = on == true
  if on == G.blocked then return end
  BreakGateCall(on and "reforged_gate_block" or "reforged_gate_unblock")
  G.blocked = on
  print(string.format("[Reforged] break-gate block=%s why=%s round=%s", tostring(on), tostring(why), tostring(REFORGED.round)))
  WatchEmit("gate", { on = on, why = why, round = REFORGED.round })
end
function BreakGateCommand(arg1)
  local G = BREAK_GATE
  if arg1 == "load" then
    BreakGateLoad()
  elseif arg1 == "on" then
    G.use = true
  elseif arg1 == "off" then
    G.use = false
    BreakGateSet(false, "command-off")
  elseif arg1 == "block" or arg1 == "unblock" then
    if not G.patched then print("[Reforged] break-gate rejected: not patched (send break-gate load)"); return end
    BreakGateSet(arg1 == "block", "command")
  elseif arg1 ~= nil and arg1 ~= "" and arg1 ~= "status" then
    print("[Reforged] command rejected: break-gate takes on, off, load, block, unblock or status")
    return
  end
  print(string.format("[Reforged] break-gate loaded=%s patched=%s blocked=%s hits=%s use=%s err=%s", tostring(G.loaded), tostring(G.patched),
    tostring(G.patched and BreakGateCall("reforged_gate_blocked") or false), tostring(G.patched and BreakGateCall("reforged_gate_hits") or false),
    G.use == false and "off" or "on", tostring(G.err)))
end

-- Endless map loads use the game's own campaign mission flow. The Endless campaign pointer comes from the live game instance. Each mission GUID is the Endless mission proto (<row>_End) from the Endless campaign mission list compare (stock rows). The old start-endless-colosseum GUID was the campaign proto Scenario_17.
local endlessStartRequested = false
local mapWatchStarted = false
local function WatchEndlessMap(gi)
  if mapWatchStarted then return end
  mapWatchStarted = true
  local mapReady = false
  GameLoop(2000, function()
    do
      local function gtBody()
        -- Two queued callbacks can run before the first one ends. The flag is set first, so the second one returns here.
        if mapReady then return end
        local c = coordinator()
        if c then
          mapReady = true
          local missionName = "?"
          pcall(function() missionName = gi:GetCurrentMissionLevelName() end)
          HookGoBreaks()
          HOOK_TRACE = {}
          DOOR_PENDING = {}
          if MAP_READY.claim(c) then
            pcall(NoScoreUpload, "map-ready")
            WatchMapReady(missionName)
            print("[Reforged] auto-test map ready mission-level=" .. tostring(missionName) .. " " .. population(c))
          end
          ApplyMapSettings(c)
          -- The map is ready, so the next launch may start. Clear the watch flag too, or a later launch would not watch.
          endlessStartRequested = false
          mapWatchStarted = false
        end
      end
      gtBody()
    end
    return mapReady
  end)
end
WatchEndlessMapForTest = WatchEndlessMap -- the offline test calls this alias; the game does not use it
-- Endless missions by mission row. The rows are copied from the Endless map list.
-- The table and the launch function sit in one do block, so the main chunk adds no top-level locals.
do
  local MISSIONS = {
    { row = "Scenario_01_End", guid = "EB77BAEE-4529-E514-DB05-58A8539D8F6A", level = "Scenario_01", name = "North Wing" },
    { row = "Scenario_02_End", guid = "64C233E3-473E-8D33-1274-A79E7F735C91", level = "Scenario_02", name = "Great Room" },
    { row = "Scenario_03_End", guid = "1E00D8B9-499F-4F07-F35A-43BC0D27FAD2", level = "Scenario_03", name = "Side Entrance" },
    { row = "Scenario_04_End", guid = "C46A265D-458D-F41C-0DE5-8BBAC8234A1E", level = "Scenario_04", name = "Hidden Dock" },
    { row = "Scenario_05_End", guid = "49A8AE8C-4735-A56A-D531-B58DCB229CCE", level = "Scenario_05", name = "Split Stairs" },
    { row = "Scenario_07_End", guid = "44DDB748-4BFD-6046-2742-20BE26B0ABCB", level = "Scenario_07", name = "Close Quarters" },
    { row = "Scenario_Other_02_End", guid = "F40168BD-44AC-365E-C61D-8EA68E8BB567", level = "Scenario_Other_02", name = "Switchbacks" },
    { row = "Scenario_08_End", guid = "A0837EC2-4D7A-E65D-3BC1-CE81F4405DCE", level = "Scenario_08", name = "Cliffside" },
    { row = "Scenario_10_End", guid = "F0D8E68E-4C70-A713-29D8-2C8B8236703B", level = "Scenario_10", name = "Coastal Hallways" },
    { row = "Scenario_11_End", guid = "68DD98D4-48F3-9079-A5C5-87BFFB34FF12", level = "Scenario_11", name = "Secret Fortress" },
    { row = "Scenario_13_End", guid = "C12855CE-4B1A-46C6-D126-26B279EF47A1", level = "Scenario_13", name = "Master's Courtyard" },
    { row = "Scenario_14_End", guid = "5D3E7FA1-478E-0F2C-78EE-71B8F7AC7878", level = "Scenario_14", name = "Sludge Shelves" },
    { row = "Scenario_Other_03_End", guid = "91E2DBC6-4FC4-5453-60D5-DBA8F3906D0D", level = "Scenario_Other_03", name = "Quick Path" },
    { row = "Scenario_16_End", guid = "6C3E1E70-4476-9B96-F727-30ABD4DA25E1", level = "Scenario_16", name = "The Basement" },
    { row = "Scenario_17_End", guid = "1D6384E5-4272-0A49-3332-8EBC07D1CE37", level = "Scenario_17", name = "Colosseum" },
    { row = "DLCScenario_01_End", guid = "97CFCC98-4C44-BB5D-CF4E-41890057ACC8", level = "ScenarioDLC_01", name = "Abandoned Passage" },
    { row = "DLCScenario_02_End", guid = "5DFE3168-472B-0FE7-BE1D-649F2352E108", level = "ScenarioDLC_02", name = "Aqueducts" },
    { row = "DLCScenario_04_End", guid = "C3DC0E5D-4A45-ED13-8812-B1B580965685", level = "ScenarioDLC_04", name = "Order Enclave" },
    { row = "DLCScenario_05_End", guid = "0D018CD4-4753-5DFB-D3C6-64A1CD9E5845", level = "ScenarioDLC_05", name = "Slag Field" },
    { row = "Scenario_Ice_01_End", guid = "80990430-45BE-92C2-88F2-EA9931500372", level = "Scenario_Ice_01", name = "Northern Rampart" },
    { row = "Scenario_Ice_02_End", guid = "E942B9B6-4F7E-412D-B675-E5AC296C3C74", level = "Scenario_Ice_02", name = "Icebound Mine" },
    { row = "Scenario_Ice_03_End", guid = "043A7A0C-4C19-9F11-2D9E-E59E1D091675", level = "Scenario_Ice_03", name = "Frostbitten" },
    { row = "Scenario_Sand_04_End", guid = "6A4561FD-43CD-58B4-E301-858D5422098E", level = "Scenario_Sand_04", name = "Sandstorm Shelter" },
    { row = "Scenario_Sand_05_End", guid = "25DE44F8-4739-183F-EF05-80BC4220B497", level = "Scenario_Sand_05", name = "Oasis Outpost" },
    { row = "Scenario_Sand_01_End", guid = "A8DBBA04-46DF-9EA2-1CA4-E9A2B46B1AB3", level = "Scenario_Sand_01", name = "Untrained Grounds" },
    { row = "Scenario_Sand_02_End", guid = "A9E7B7F3-45D4-A087-605E-48A7068963C6", level = "Scenario_Sand_02", name = "Sand Sea Castle" },
    -- War Scenario maps (#101). Rows from Mods/Reforged/war-scenarios.tsv. The pak zz_ReforgedWarScenarios_P adds them to the game.
    { row = "Scenario_06_WS_End", guid = "F7E1EB46-416B-5F24-8203-57F4152CB20D", level = "Scenario_06", name = "The Lava Pits" },
    { row = "Scenario_09_WS_End", guid = "FA8A3837-0399-5E67-BA7B-30BF7308A9FE", level = "Scenario_09", name = "Front Lawn" },
    { row = "Scenario_12_WS_End", guid = "A4DE6B98-DA12-5DD9-96CD-20E2D4A066AE", level = "Scenario_15", name = "Mage Tower" },
    { row = "Scenario_15_WS_End", guid = "9BB56BAA-A145-53FD-AA7B-631D3E40D7A9", level = "Scenario_12", name = "Dragon Boneyard" },
    { row = "Scenario_18_WS_End", guid = "8D8BD691-894E-5FF9-9FA4-2C062236020D", level = "Scenario_18", name = "Order Temple" },
    { row = "DLCScenario_03_WS_End", guid = "16A1DA65-1E18-5C60-B632-442233E6F463", level = "ScenarioDLC_03", name = "Canyon Keep" },
    { row = "Scenario_Sand_03_WS_End", guid = "4CAF6C6D-442D-57E0-9168-B4CA8E66CB27", level = "Scenario_Sand_03", name = "Desert Wall" },
    -- Custom maps (#100, #102). Rows from Mods/Reforged/custom-map-rows.tsv. The level is the Test map (/Game/Maps/Test/<level>).
    { row = "WellThatsOrcward_End", guid = "35AB4658-44C8-5E5D-B847-901217630F57", level = "WellThatsOrcward", name = "Well That's Orcward" },
    { row = "ServantEntrance_End", guid = "B6232412-0A9F-584B-B16D-A87541EFE134", level = "ServantEntrance", name = "Servant Entrance" },
  }

  local function MissionByRow(row)
    for _, entry in ipairs(MISSIONS) do
      if entry.row == row then return entry end
    end
    return nil
  end

  -- #102: a GUID word as an unsigned 32-bit integer, or nil when it is not a number.
  local function WordOf(v)
    if type(v) ~= "number" then return nil end
    local i = math.tointeger(v)
    return i and (i & 0xFFFFFFFF) or nil
  end

  -- True when the four words A, B, C, D of x and y are equal. A nil or unreadable value is not equal.
  local function GuidWordsEqual(x, y)
    if not x or not y then return false end
    for _, k in ipairs({ "A", "B", "C", "D" }) do
      local wx, wy = WordOf(x[k]), WordOf(y[k])
      if not wx or not wy or wx ~= wy then return false end
    end
    return true
  end

  -- Text of a GUID for the log, 8-4-4-4-12 hex. "unreadable" when the value could not be read.
  local function GuidWordsText(g)
    if not g then return "unreadable" end
    local hex = {}
    for i, k in ipairs({ "A", "B", "C", "D" }) do
      local w = WordOf(g[k])
      hex[i] = w and string.format("%08X", w) or "nil"
    end
    local s = table.concat(hex)
    return s:sub(1, 8) .. "-" .. s:sub(9, 12) .. "-" .. s:sub(13, 16) .. "-" .. s:sub(17, 20) .. "-" .. s:sub(21, 32)
  end

  -- Loads one Endless map by its mission row, through the stock campaign flow from the Endless hub.
  -- endlessStartRequested stays true until WatchEndlessMap sees the map ready. A failure before the load call clears it.
  StartEndlessMission = function(row)
    local entry = MissionByRow(row)
    if not entry then
      print("[Reforged] launch rejected: unknown mission row " .. tostring(row))
      return
    end
    if endlessStartRequested then
      print("[Reforged] launch rejected: a launch is already in progress")
      return
    end
    endlessStartRequested = true
    local mission = { Guid = GuidFromString(entry.guid) }
    ExecuteInGameThread(function()
      local gi
      pcall(function() gi = FindFirstOf("BP_OMDGameInstance_C") end)
      if not gi or not gi:IsValid() then
        pcall(function() gi = FindFirstOf("OMDGameInstance") end)
      end
      if not gi or not gi:IsValid() then
        endlessStartRequested = false
        print("[Reforged] launch failed: game instance unavailable")
        return
      end
      local hub = gi.CampaignScrnWidget
      if not hub or not hub:IsValid() then
        pcall(function() hub = FindFirstOf("HubScreen_UMG_C") end)
      end
      if not hub or not hub:IsValid() then
        endlessStartRequested = false
        print("[Reforged] launch failed: Endless campaign hub unavailable after menu input")
        return
      end
      local endless = gi.EndlessCampaign
      local campaign
      pcall(function()
        local g = endless.Guid
        campaign = { Guid = { A = g.A, B = g.B, C = g.C, D = g.D } }
      end)
      if not campaign then
        endlessStartRequested = false
        print("[Reforged] launch failed: cannot read the Endless campaign GUID")
        return
      end
      local okCampaign, campaignErr = pcall(function() gi:SetCurrentCampaign(campaign) end)
      SetEndlessDifficulty("launch")
      print("[Reforged] launch row=" .. entry.row .. " level=" .. entry.level .. " name=" .. entry.name .. " guid=" .. entry.guid)
      local okMission, missionErr = pcall(function() gi:SetCurrentMission(mission) end)
      print(string.format("[Reforged] auto-test set campaign=%s error=%s mission=%s error=%s",
        tostring(okCampaign), tostring(campaignErr), tostring(okMission), tostring(missionErr)))
      if not okCampaign or not okMission then
        endlessStartRequested = false
        return
      end
      -- #102: SetCurrentMission does nothing when the GUID is not in the campaign's MissionList, and it reports no error.
      -- Read the current mission back. Launch only when it is the row that was asked for.
      local okRead, current = pcall(function()
        local g = gi.CurrentMission.Guid
        return { A = g.A, B = g.B, C = g.C, D = g.D }
      end)
      if not okRead then current = nil end
      if not GuidWordsEqual(current, mission.Guid) then
        endlessStartRequested = false
        print("[Reforged] launch rejected: mission not set row=" .. entry.row .. " current=" .. GuidWordsText(current))
        return
      end
      print("[Reforged] launch mission set row=" .. entry.row .. " ok=true")
      local okLoad, loadErr = pcall(function() hub:Manual_SinglePlayer_LaunchGame() end)
      print(string.format("[Reforged] auto-test Manual_SinglePlayer_LaunchGame called=%s error=%s",
        tostring(okLoad), tostring(loadErr)))
      if okLoad then
        WatchEndlessMap(gi)
      else
        endlessStartRequested = false
      end
    end)
  end
end

-- Route probe. Fork weights live on OMDPathPoint.NextPoints[].BranchWeight.
-- route-reload calls the Blueprint UFunction LoadPathFromLevel, which rebuilds the controller's native node list.
local function RoutePoints()
  local ok, pts = pcall(FindAllOf, "OMDPathPoint")
  if not ok or not pts then return {} end
  return pts
end

-- Colosseum forks. Other points have one successor; reading np[2] there returns garbage.
local COLOSSEUM_FORKS = { [8] = true, [2] = true, [14] = true }

local function RouteWeights()
  for _, p in ipairs(RoutePoints()) do
    pcall(function()
      if not COLOSSEUM_FORKS[p.PointIndex] then return end
      local np = p.NextPoints
      local a, b = np[1], np[2]
      if not a or not b then return end
      if a.PointIndex < 0 or b.PointIndex < 0 then return end
      print(string.format("[Reforged] route fork point=%d branches %d=%.2f %d=%.2f",
        p.PointIndex, a.PointIndex, a.BranchWeight, b.PointIndex, b.BranchWeight))
    end)
  end
end

-- Read-only: list every path point with two or more successors and their weights. The length is read first,
-- because reading NextPoints[2] on a one-successor point returned garbage and locked the game on Colosseum.
local function RouteForks()
  local pts = RoutePoints()
  print("[Reforged] route-forks points=" .. tostring(#pts))
  for _, p in ipairs(pts) do
    pcall(function()
      local np = p.NextPoints
      local okN, n = pcall(function() return #np end)
      if not okN then n = "ERR " .. tostring(n) end
      print(string.format("[Reforged] route point=%s successors=%s", tostring(p.PointIndex), tostring(n)))
      if not okN or not n or n < 2 or n > 6 then return end
      local parts = {}
      for i = 1, n do
        local br = np[i]
        parts[#parts + 1] = string.format("%d=%.2f", br.PointIndex, br.BranchWeight)
      end
      print(string.format("[Reforged] route fork point=%d n=%d branches %s", p.PointIndex, n, table.concat(parts, " ")))
    end)
  end
  print("[Reforged] route-forks done")
end

local function RouteSet(pointIndex, branchIndex, weight)
  for _, p in ipairs(RoutePoints()) do
    if p.PointIndex == pointIndex then
      for i = 1, 4 do
        local ok, br = pcall(function() return p.NextPoints[i] end)
        if ok and br and br.PointIndex == branchIndex then
          br.BranchWeight = weight
          print(string.format("[Reforged] route-set point=%d branch=%d weight=%.2f readback=%.2f",
            pointIndex, branchIndex, weight, br.BranchWeight))
          return
        end
      end
    end
  end
  print(string.format("[Reforged] route-set rejected: no point %d branch %d", pointIndex, branchIndex))
end

local function RouteControllers()
  local found = {}
  local ok, list = pcall(FindAllOf, "OMDAIController")
  if not ok or not list then return found end
  for _, c in ipairs(list) do
    pcall(function()
      if not c:IsValid() or not c.Pawn or not c.Pawn:IsValid() then return end
      if c.Pawn:GetFullName():find("BP_Wisp_") then return end
      found[#found + 1] = c
    end)
  end
  return found
end

local function RouteReload(count)
  local list = RouteControllers()
  for i = 1, math.min(count, #list) do
    local c = list[i]
    local okA, addr = pcall(function() return c:GetAddress() end)
    local okR, err = pcall(function() c:LoadPathFromLevel() end)
    print(string.format("[Reforged] route-reload orc=%s ok=%s%s", tostring(okA and addr or "?"), tostring(okR),
      okR and "" or (" err=" .. tostring(err))))
  end
  print(string.format("[Reforged] route-reload done: %d of %d non-Wisp controllers", math.min(count, #list), #list))
end

local function RouteWhere()
  local pts = RoutePoints()
  for _, c in ipairs(RouteControllers()) do
    pcall(function()
      local okA, addr = pcall(function() return c:GetAddress() end)
      local loc = c.Pawn:K2_GetActorLocation()
      local best, bestD = -1, math.huge
      for _, p in ipairs(pts) do
        local okP, pl = pcall(function() return p:K2_GetActorLocation() end)
        if okP and pl then
          local dx, dy, dz = loc.X - pl.X, loc.Y - pl.Y, loc.Z - pl.Z
          local d = math.sqrt(dx * dx + dy * dy + dz * dz)
          if d < bestD then best, bestD = p.PointIndex, d end
        end
      end
      print(string.format("[Reforged] route-where orc=%s near=%d d=%.0f loc=%.0f,%.0f",
        tostring(okA and addr or "?"), best, bestD, loc.X, loc.Y))
    end)
  end
end

-- Start the next Endless wave without the G key (no window focus needed).
-- EOnslaughtDifficulty: 4 = Endless.
local function GoBreakCommand()
  local c = coordinator()
  if not c then print("[Reforged] go rejected: no coordinator"); return end
  local ok, err = pcall(function() c:OnslaughtGoBreak(4) end)
  print(string.format("[Reforged] go OnslaughtGoBreak(4) ok=%s%s", tostring(ok), ok and "" or (" err=" .. tostring(err))))
end

-- Read-only: log the player pawn's movement ability and whether Feign Death is active.
-- The runner polls this and presses G only after active=true.
local function PlayerState()
  local pc, pawn
  pcall(function() pc = FindFirstOf("OMDPlayerController") end)
  if pc and pc:IsValid() then pcall(function() pawn = pc.Pawn end) end
  if not pawn or not pawn:IsValid() then print("[Reforged] player-state pawn=none"); return end
  local moveType, active = "?", "?"
  pcall(function() moveType = pawn.MoveAbilityType end)
  pcall(function() active = pawn.bMoveAbilityActive end)
  print(string.format("[Reforged] player-state pawn=ok movement=%s active=%s", tostring(moveType), tostring(active)))
end

-- Read-only: list game functions whose names suggest a wave start, on the objects G could reach.
local function FnDump()
  local targets = {}
  local okP, pc = pcall(function() return FindFirstOf("OMDPlayerController") end)
  if okP and pc then targets[#targets + 1] = { "controller", pc } end
  local okG, gs = pcall(function() return FindFirstOf("OMDGameState") end)
  if okG and gs then targets[#targets + 1] = { "gamestate", gs } end
  local c = coordinator()
  if c then targets[#targets + 1] = { "coordinator", c } end
  for _, t in ipairs(targets) do
    pcall(function()
      t[2]:GetClass():ForEachFunction(function(fn)
        local name = fn:GetFName():ToString()
        local l = name:lower()
        if l:find("break") or l:find("unleash") or l:find("startgroup") or l:find("wave") or l:find("start") then
          print("[Reforged] fn-dump " .. t[1] .. " " .. name)
        end
      end)
    end)
  end
  print("[Reforged] fn-dump done")
end

-- Candidate for what G does: OMDGameState:GoBreak (listed by fn-dump). No key press needed.
local function GameStateGoBreak()
  local okG, gs = pcall(function() return FindFirstOf("OMDGameState") end)
  if not okG or not gs then print("[Reforged] go2 rejected: no game state"); return end
  local ok, err = pcall(function() gs:GoBreak() end)
  print(string.format("[Reforged] go2 GameState:GoBreak ok=%s%s", tostring(ok), ok and "" or (" err=" .. tostring(err))))
end

-- Queue block (levers 1 and 2). Classic never swaps or holds.
-- QUEUE_BLOCK: true on, false off, nil auto (on in Manual only). The key swap writes QUEUE_BLOCK_KEY into the coordinator's
-- ReforgedSpawnKey (+0x3ec) around each native spawn call, so no spawn record matches. TICK_HOLD mirrors ReforgedHold (+0x3f4).
-- New names are globals (the main chunk is near the 200-local limit of Lua 5.4).
QUEUE_BLOCK = nil
QUEUE_BLOCK_KEY = -7777
QBLOCK = { saved = nil, coord = nil, swapped = 0, restored = 0 }
TICK_HOLD = false
-- The mode the queue block uses: the saved mode in endless-mode.txt. The native build calls the spawn hook before
-- the mode is applied, so ENDLESS_MODE can still be classic then. The file is read once per second
-- (the build makes about 464 calls in one burst). If the read fails, the applied mode is used and not cached.
function QueueBlockMode()
  local now = os.time()
  if QBLOCK.mode ~= nil and QBLOCK.modeAt == now then return QBLOCK.mode end
  local okM, mode = pcall(function() return ReadEndlessMode() end)
  if not okM or mode == nil then return ENDLESS_MODE end
  QBLOCK.mode = mode
  QBLOCK.modeAt = now
  return mode
end
-- The level-load popup. Title is the Endless mode. Line is TEST MODE when test mode is on, else nil.
-- Returns title, line, shown. shown is true only when HudBannerShow ran and returned true.
-- When the first show is shown, a second pass runs MODE_BANNER_PASS2_MS later and holds the end of the animation.
MODE_BANNER_PASS2_MS = 1700 -- 50 ms before the first banner removes itself (1.75 s), so there is no gap
-- The visible part of the stock banner animation (Animate). Fade in 0 to 0.35 s, solid to 1.35 s, fade out to 1.70 s.
BANNER_PLATEAU_T = 0.85 -- seconds on the solid part; a held widget is paused here
BANNER_FADEOUT_T = 1.35 -- seconds where the fade-out starts; a hold end plays from here
BANNER_PLATEAU_DELAY_MS = 500 -- ms after the first show, before the first pass is held on the plateau
MODE_BANNER_HOLD_MS = 3500 -- the level-load popup: about its length
-- The game state address, or nil when it cannot be read.
function ModeBannerStateAddress()
  local okA, addr = pcall(function() return FindFirstOf("OMDGameState"):GetAddress() end)
  if okA then return addr end
  return nil
end
function ModeBannerShow()
  local okM, mode = pcall(QueueBlockMode)
  if not okM then mode = nil end
  local titles = { classic = "CLASSIC ENDLESS", manual = "MANUAL ENDLESS", reforged = "REFORGED ENDLESS" }
  local title = titles[mode] or "ENDLESS"
  -- The second line joins TEST MODE and MODIFIERS ON with " - ". Nil when neither applies.
  local parts = {}
  if TEST_MODE == true then parts[#parts + 1] = "TEST MODE" end
  local okMod, modOn = pcall(function()
    if mode == "reforged" then return ModifierSettingRead("waveModifiers") == "on" end
    if mode == "classic" then return ModifierSettingRead("modifiersInClassic") == "on" end
    return false
  end)
  if okMod and modOn == true then parts[#parts + 1] = "MODIFIERS ON" end
  local line = nil
  if #parts > 0 then line = table.concat(parts, " - ") end
  -- One popup per map. The game state address marks the map.
  local addr = ModeBannerStateAddress()
  if addr ~= nil and HUD_BANNER.modeAddr == addr then
    print("[Reforged] mode-banner skipped reason=already-shown")
    return title, line, false
  end
  HUD_BANNER.readd = {} -- A new show drops the widgets of the last map
  -- The hold ends the popup at MODE_BANNER_HOLD_MS (its length) through the fade-out.
  local shown = BannerLong(title, line, "mode", { holdMs = MODE_BANNER_HOLD_MS })
  print(string.format("[Reforged] mode-banner title=%s line=%s shown=%s", title, line or "none", tostring(shown)))
  if shown then
    HUD_BANNER.modeAddr = addr
    HUD_BANNER.modeShownAt = os.time() -- A modifier popup within 4 s of this one waits (wall seconds)
  end
  return title, line, shown
end
function QueueBlockActive()
  local mode = QueueBlockMode()
  if mode == "classic" then return false end
  if QUEUE_BLOCK ~= nil then return QUEUE_BLOCK end
  return mode == "manual" or mode == "reforged"
end
function QueueBlockValid(obj)
  if obj == nil then return false end
  local okV, v = pcall(function() return obj:IsValid() end)
  return okV and v == true
end
-- Writes the saved key back. Shared by the post hook and the pre hooks of the other Onslaught entries.
function QueueBlockRestore()
  if QBLOCK.saved == nil then return end
  local v, c = QBLOCK.saved, QBLOCK.coord
  QBLOCK.saved = nil
  if c ~= nil then pcall(function() c.ReforgedSpawnKey = v end) end
  QBLOCK.restored = QBLOCK.restored + 1
end
-- Pre hook body. The coordinator is self when valid, else FindFirstOf. A key that cannot be read is not swapped.
function QueueBlockSwap(hookSelf)
  if not QueueBlockActive() then return end
  QueueBlockRestore() -- a missed restore must not be read back as the real key
  local c = nil
  local okS, cs = pcall(function() return hookSelf:get() end)
  if okS and QueueBlockValid(cs) then c = cs end
  if c == nil then
    local okF, cf = pcall(FindFirstOf, "OMDOnslaughtCoordinator")
    if okF and QueueBlockValid(cf) then c = cf end
  end
  if c == nil then return end
  local okR, key = pcall(function() return c.ReforgedSpawnKey end)
  if not okR or key == nil then return end
  QBLOCK.coord = c
  QBLOCK.saved = key
  pcall(function() c.ReforgedSpawnKey = QUEUE_BLOCK_KEY end)
  QBLOCK.swapped = QBLOCK.swapped + 1
end
function QueueBlockStatus()
  local setting = "auto"
  if QUEUE_BLOCK == true then setting = "on" elseif QUEUE_BLOCK == false then setting = "off" end
  local okF, c = pcall(FindFirstOf, "OMDOnslaughtCoordinator")
  local key = nil
  if okF and QueueBlockValid(c) then
    local okK, v = pcall(function() return c.ReforgedSpawnKey end)
    if okK then key = v end
  end
  print(string.format("[Reforged] queue-block setting=%s active=%s mode=%s applied=%s swapped=%d restored=%d key=%s",
    setting, tostring(QueueBlockActive()), tostring(QueueBlockMode()), tostring(ENDLESS_MODE), QBLOCK.swapped, QBLOCK.restored, tostring(key)))
end
function QueueBlockCommand(arg)
  if arg == "on" then QUEUE_BLOCK = true
  elseif arg == "off" then QUEUE_BLOCK = false
  elseif arg == "auto" then QUEUE_BLOCK = nil end
  QueueBlockStatus()
end
-- Prints the hold state and the coordinator's ReforgedHold. Writes nothing.
function TickHoldPrint()
  local okF, c = pcall(FindFirstOf, "OMDOnslaughtCoordinator")
  local read = nil
  if okF and QueueBlockValid(c) then
    local okR, v = pcall(function() return c.ReforgedHold end)
    if okR then read = v end
  end
  print(string.format("[Reforged] tick-hold on=%s read=%s", tostring(TICK_HOLD == true), tostring(read)))
end
-- Automatic hold. TICK_HOLD_AUTO is the switch. TICK_HOLD_AUTO_ON is true only while the automatic step holds.
TICK_HOLD_AUTO = true
TICK_HOLD_GRACE = 4
REFORGED_HOLD_GRACE = 1 -- the grace in Reforged when no work is pending
TICK_HOLD_AUTO_ON = false
TICK_HOLD_FREE_SINCE = nil
-- Set by the hoard release (os.time value). The hold stays on until then, so released door calls do not end the round.
TICK_HOLD_UNTIL = 0
function TickHoldAutoPrint()
  print(string.format("[Reforged] tick-hold auto=%s autoOn=%s", tostring(TICK_HOLD_AUTO == true), tostring(TICK_HOLD_AUTO_ON == true)))
end
function TickHoldAutoCommand(arg)
  if arg == "on" then
    TICK_HOLD_AUTO = true
  elseif arg == "off" then
    TICK_HOLD_AUTO = false
    -- Turning the switch off releases only a hold that the automatic step made. A manual hold stays.
    if TICK_HOLD_AUTO_ON == true then
      TickHold(false)
      TICK_HOLD_AUTO_ON = false
      TICK_HOLD_FREE_SINCE = nil
    end
  else
    print("[Reforged] tick-hold auto rejected: use tick-hold auto on|off")
    return
  end
  print("[Reforged] tick-hold auto=" .. tostring(TICK_HOLD_AUTO == true))
end
-- One step, once per second. It holds while director pawns stand or the director wave is open. It releases only
-- after the hold has seen no director pawns and no open wave for TICK_HOLD_GRACE seconds in a row.
-- In Reforged with no pending work (no pawn, no pace call, no director wave, no hoard window, no door call) the grace is REFORGED_HOLD_GRACE.
-- It also holds until TICK_HOLD_UNTIL (set by the hoard release). Called from the hoard release loop, once per pass.
-- In a timed break the hold is not turned on. An existing hold ends by the grace rule below.
function TickHoldAutoStep()
  if TICK_HOLD_AUTO ~= true or not QueueBlockActive() then return end
  local standing = StandingCount()
  local now = os.time()
  local paceWaiting = #PACE_QUEUE > 0
  local timedWait = ReforgedTimedWait()
  -- A countdown does not turn the hold on. The hold starts at the countdown end (ReforgedBreakHoldArm).
  local countdown = TICK_HOLD ~= true and ReforgedCountdownNow()
  if BreakGateActive() then
    -- Break gate: the gate replaces the tick hold. A hold from before is released at once.
    if TICK_HOLD == true and TICK_HOLD_AUTO_ON == true then
      TickHold(false)
      TICK_HOLD_AUTO_ON = false
    end
    -- The gate does not freeze a countdown, so a countdown counts as pending work here.
    -- Calls held by the hoard gate before G count as pending work too.
    local hoardWaiting = type(HOARD_HELD) == "table" and #HOARD_HELD > 0
    local wantGate = standing > 0 or waveTrack.active == true or now < TICK_HOLD_UNTIL or paceWaiting or hoardWaiting
    if wantGate then
      TICK_HOLD_FREE_SINCE = nil
      -- Stale pending state after a map is left (no game state): do not re-block. Block only with a game state and REFORGED ready.
      local gameStateOk = true
      do
        local okS, relS, reasonS = pcall(HoardReleased)
        if okS and relS == false and reasonS == "no-game-state" then gameStateOk = false end
      end
      if BREAK_GATE.blocked ~= true and REFORGED.round >= 1 and gameStateOk and REFORGED.ready == true then BreakGateSet(true, "pending") end
    elseif BREAK_GATE.blocked == true then
      if TICK_HOLD_FREE_SINCE == nil then TICK_HOLD_FREE_SINCE = now end
      local grace = TICK_HOLD_GRACE
      if QueueBlockMode() == "reforged" and (not timedWait) and (not countdown) and standing == 0 and #PACE_QUEUE == 0
        and waveTrack.active ~= true and now >= TICK_HOLD_UNTIL and not DoorCallsPending() and not hoardWaiting then
        grace = REFORGED_HOLD_GRACE
      end
      if now - TICK_HOLD_FREE_SINCE >= grace then
        -- Round chain: a round with no break keeps the gate closed. The next round is built instead.
        if ReforgedBreakChainHold() then return end
        BreakGateSet(false, "clear")
        TICK_HOLD_FREE_SINCE = nil
        WatchEmit("hold", { on = false, standing = 0, reason = "clear", grace = grace, gate = true }) -- hold event: see the watch stream
      end
    end
    return
  end
  local want = (not timedWait) and (not countdown) and (standing > 0 or waveTrack.active == true or now < TICK_HOLD_UNTIL or paceWaiting)
  if want then
    TICK_HOLD_FREE_SINCE = nil
    if TICK_HOLD ~= true then
      local reason = "release-window"
      if standing > 0 then reason = "director-pawns" elseif waveTrack.active == true then reason = "director-wave"
      elseif now >= TICK_HOLD_UNTIL and paceWaiting then reason = "pace-queue" end
      TickHold(true)
      TICK_HOLD_AUTO_ON = true
      WatchEmit("hold", { on = true, standing = standing, reason = reason }) -- hold event: see the watch stream
    end
  elseif TICK_HOLD == true and TICK_HOLD_AUTO_ON == true then
    if TICK_HOLD_FREE_SINCE == nil then TICK_HOLD_FREE_SINCE = now end
    local grace = TICK_HOLD_GRACE
    if QueueBlockMode() == "reforged" and (not timedWait) and (not countdown) and standing == 0 and #PACE_QUEUE == 0
      and waveTrack.active ~= true and now >= TICK_HOLD_UNTIL and not DoorCallsPending() then
      grace = REFORGED_HOLD_GRACE
    end
    if now - TICK_HOLD_FREE_SINCE >= grace then
      -- Round chain: a round with no break does not release. The next round is built instead.
      if ReforgedBreakChainHold() then return end
      TickHold(false)
      TICK_HOLD_AUTO_ON = false
      TICK_HOLD_FREE_SINCE = nil
      WatchEmit("hold", { on = false, standing = 0, reason = "clear", grace = grace }) -- hold event: see the watch stream
    end
  end
end
-- True while a countdown runs in Reforged: a timed break, or no Go Break with the timer above 0.2 s. A failed read gives false.
function ReforgedCountdownNow()
  if QueueBlockMode() ~= "reforged" then return false end
  local goB, timed = ReforgedBreakFlags()
  if goB == nil then return false end
  if timed == true then return true end
  if goB ~= false then return false end
  local timer = ReforgedTimerNow()
  return timer ~= nil and timer > 0.2
end

-- Turns the tick hold on at the countdown end. Returns true when it turned the hold on, else false and the reason.
-- Called by the TimedBreak hook (timed-event) and the fast check (fast-check, fast-check-timed).
function ReforgedBreakHoldArm(via)
  if BreakGateActive() then return false, "gate" end
  if QueueBlockMode() ~= "reforged" then return false, "mode" end
  if TICK_HOLD_AUTO ~= true then return false, "auto-off" end
  if not QueueBlockActive() then return false, "queue-block-off" end
  if TICK_HOLD == true then return false, "already-on" end
  if REFORGED.round < 1 then return false, "round-0" end
  local standing = StandingCount()
  local now = os.time()
  if not (#PACE_QUEUE > 0 or standing > 0 or waveTrack.active == true or now < TICK_HOLD_UNTIL) then return false, "nothing-pending" end
  TickHold(true)
  TICK_HOLD_AUTO_ON = true
  TICK_HOLD_FREE_SINCE = nil
  BREAK_ORDER.watch = nil
  local timer = ReforgedTimerNow()
  print(string.format("[Reforged] round hold at countdown end via=%s round=%s timer=%s", tostring(via), tostring(REFORGED.round), tostring(timer or "?")))
  WatchEmit("hold", { on = true, standing = standing, reason = "countdown-end", via = via })
  return true
end

-- The round chain at a round with no break. Returns true when it chained: the hold stays on and ReforgedStep builds the next round.
function ReforgedBreakChainHold()
  local W = BREAK_ORDER
  if QueueBlockMode() ~= "reforged" or W.chain == true then return false end
  local okE, kind = pcall(ReforgedBreakExpectedNext, REFORGED.round)
  if not okE or kind ~= "none" then return false end
  local r = REFORGED.round
  W.chain = true
  -- With the gate the stock wave is not held, so CurrentWave stays equal to the round. No offset then.
  if not BreakGateActive() then W.offset = W.offset + 1 end
  TICK_HOLD_FREE_SINCE = nil
  print(string.format("[Reforged] break order chain: round %s has no break, round %s starts now", tostring(r), tostring(r + 1)))
  return true
end

function TickHold(on)
  if on then
    if QueueBlockMode() == "classic" then
      print("[Reforged] tick-hold refused mode=classic")
      return
    end
    local okF, c = pcall(FindFirstOf, "OMDOnslaughtCoordinator")
    if okF and QueueBlockValid(c) then pcall(function() c.ReforgedHold = 1 end) end
    TICK_HOLD = true
  else
    local okF, c = pcall(FindFirstOf, "OMDOnslaughtCoordinator")
    local okE = false
    if okF and QueueBlockValid(c) then okE = pcall(function() c:OnslaughtEnd() end) end
    if not okE and okF and QueueBlockValid(c) then pcall(function() c.ReforgedHold = 0 end) end
    TICK_HOLD = false
  end
  TickHoldPrint()
end

-- Endless count probe. The hook logs each native OnslaughtSpawnEntities call (the requested arguments) and can
-- override EndlessAddCount and EndlessPromotePercent. nil means stock. Distinct pawns seen per round are tallied by name.
local endlessAddOverride, endlessPromoteOverride = nil, nil
local req = { calls = 0, count = 0, add = 0, promoteMax = 0 }
local tally = { set = {}, n = 0, classes = {} }
local function EndlessIteration()
  local c = coordinator()
  if not c then return "?" end
  local ok, v = pcall(function() return c:GetEndlessIteration() end)
  return ok and tostring(v) or "?"
end
local function TallyReset()
  req = { calls = 0, count = 0, add = 0, promoteMax = 0 }
  tally = { set = {}, n = 0, classes = {} }
  print("[Reforged] tally reset iter=" .. EndlessIteration())
end
local function TallyPrint()
  local parts = {}
  for name, n in pairs(tally.classes) do parts[#parts + 1] = name .. "=" .. n end
  table.sort(parts)
  print(string.format("[Reforged] tally iter=%s requested_calls=%d requested_count=%d requested_addcount=%d promote_max=%.2f observed_distinct=%d override add=%s promote=%s classes=%s",
    EndlessIteration(), req.calls, req.count, req.add, req.promoteMax, tally.n, tostring(endlessAddOverride),
    tostring(endlessPromoteOverride), table.concat(parts, ",")))
end
local okSpawnHook, errSpawnHook = SafeRegisterHook("/Script/OMD.OMDOnslaughtCoordinator:OnslaughtSpawnEntities",
  function(self, proto, count, shield, addCount, promote, difficulty)
    HookTrace("OnslaughtSpawnEntities")
    local function get(p) local ok, v = pcall(function() return p:get() end); return ok and v or nil end
    local c, a, pr = get(count), get(addCount), get(promote)
    req.calls = req.calls + 1
    req.count = req.count + (tonumber(c) or 0)
    req.add = req.add + (tonumber(a) or 0)
    if tonumber(pr) and tonumber(pr) > req.promoteMax then req.promoteMax = tonumber(pr) end
    if TESTING and req.calls <= 12 then
      print(string.format("[Reforged] spawn-entities call #%d iter=%s count=%s add=%s promote=%s", req.calls, EndlessIteration(), tostring(c), tostring(a), tostring(pr)))
    end
    if TESTING and req.calls <= 6 then
      local okP, g = pcall(function()
        local st = proto:get()
        return string.format("A=%s B=%s C=%s D=%s", tostring(st.Guid.A), tostring(st.Guid.B), tostring(st.Guid.C), tostring(st.Guid.D))
      end)
      print("[Reforged] spawn-entities proto call #" .. req.calls .. " " .. (okP and g or ("ERR " .. tostring(g))))
    end
    if TESTING and req.calls <= 3 then
      local raw = {}
      for i, p in ipairs({ proto, count, shield, addCount, promote, difficulty }) do
        local okG, v = pcall(function() return p:get() end)
        raw[#raw + 1] = string.format("p%d type=%s get=%s", i, type(p), okG and tostring(v) or ("ERR " .. tostring(v)))
      end
      print("[Reforged] spawn-entities raw " .. table.concat(raw, " | "))
    end
    if endlessAddOverride ~= nil then pcall(function() addCount:set(endlessAddOverride) end) end
    if endlessPromoteOverride ~= nil then pcall(function() promote:set(endlessPromoteOverride) end) end
    QueueBlockSwap(self)
  end, function() QueueBlockRestore() end)
print("[Reforged] OnslaughtSpawnEntities hook registered=" .. tostring(okSpawnHook) .. " " .. tostring(errSpawnHook))
do
  local okFormation = SafeRegisterHook("/Script/OMD.OMDOnslaughtCoordinator:OnslaughtSpawnEntitiesFormation",
    function(self) QueueBlockSwap(self) end, function() QueueBlockRestore() end)
  print("[Reforged] OnslaughtSpawnEntitiesFormation hook registered=" .. tostring(okFormation))
  local guardCount = 0
  for _, name in ipairs({ "OnslaughtDelay", "OnslaughtGoBreak", "OnslaughtWaveBreak", "OnslaughtGiveCoin", "OnslaughtAction", "OnslaughtStartGroup" }) do
    local okGuard = SafeRegisterHook("/Script/OMD.OMDOnslaughtCoordinator:" .. name, function() QueueBlockRestore() end)
    if okGuard then guardCount = guardCount + 1 end
  end
  print("[Reforged] queue-block guards registered=" .. guardCount .. "/6")
end
DIAG[#DIAG + 1] = function()
  GameLoop(1000, function()
    if DiagOn() then for _, e in ipairs(LiveNonWispAI()) do
        if not tally.set[e.full] then
          tally.set[e.full] = true
          tally.n = tally.n + 1
          local cls = e.full:match("^(%S+)") or "?"
          tally.classes[cls] = (tally.classes[cls] or 0) + 1
        end
      end end
    return false
  end)
end

-- Endless stat probe. stat-sample logs min..max MaxHealth and MaxWalkSpeed per live non-Wisp class.
-- dm-read / dm-set read and write the difficulty manager's Endless modifiers. dm-set remembers each stock value, so `stock` restores it.
local function Range(t)
  if #t == 0 then return "?" end
  local lo, hi = t[1], t[1]
  for _, v in ipairs(t) do if v < lo then lo = v end; if v > hi then hi = v end end
  return string.format("%.1f..%.1f", lo, hi)
end
local function StatSample()
  local by = {}
  for _, e in ipairs(LiveNonWispAI()) do
    local a = e.actor
    local okH, mh = pcall(function() return a:GetMaxHealth() end)
    local okS, sp = pcall(function() return a.CharacterMovement.MaxWalkSpeed end)
    local cls = e.full:match("^(%S+)") or "?"
    local b = by[cls]
    if not b then b = { n = 0, hs = {}, ss = {} }; by[cls] = b end
    b.n = b.n + 1
    if okH and tonumber(mh) then b.hs[#b.hs + 1] = tonumber(mh) end
    if okS and tonumber(sp) then b.ss[#b.ss + 1] = tonumber(sp) end
  end
  local names = {}
  for cls in pairs(by) do names[#names + 1] = cls end
  table.sort(names)
  for _, cls in ipairs(names) do
    local b = by[cls]
    print(string.format("[Reforged] stat iter=%s class=%s n=%d maxHealth=%s speed=%s", EndlessIteration(), cls, b.n, Range(b.hs), Range(b.ss)))
  end
  print("[Reforged] stat done classes=" .. #names)
end
local DM_FIELDS = { "EndlessHealthModifier", "EndlessMovementSpeedModifier", "EndlessDamageModifier",
  "EndlessHealthAdditionPerWave", "EndlessMovementSpeedAdditionPerWave", "EndlessDamageAdditionPerWave",
  "EndlessIterationNoGoBreaks" } -- the last one is the Go Break setting: 0 = timed breaks (BreaksOff), stock = the game default
local function DmRead()
  local dm = DifficultyManager()
  if not dm then print("[Reforged] dm-read: no difficulty manager"); return end
  local parts = {}
  for _, k in ipairs(DM_FIELDS) do
    local ok, v = pcall(function() return dm[k] end)
    parts[#parts + 1] = string.format("%s=%s", k, ok and tostring(v) or "ERR")
  end
  print("[Reforged] dm-read iter=" .. EndlessIteration() .. " " .. table.concat(parts, " "))
end
local function DmSet(field, value)
  local known = false
  for _, k in ipairs(DM_FIELDS) do if k == field then known = true end end
  if not known then print("[Reforged] dm-set rejected: field must be one of " .. table.concat(DM_FIELDS, ", ")); return end
  local dm = DifficultyManager()
  if not dm then print("[Reforged] dm-set: no difficulty manager"); return end
  if DM_STOCK[field] == nil then
    local ok, v = pcall(function() return dm[field] end)
    if ok then DM_STOCK[field] = v end
  end
  local target = value
  if value == "stock" then target = DM_STOCK[field] else target = tonumber(value) end
  if target == nil then print("[Reforged] dm-set rejected: need a number or stock"); return end
  local ok, err = pcall(function() dm[field] = target end)
  local okR, back = pcall(function() return dm[field] end)
  print(string.format("[Reforged] dm-set %s -> %s set=%s readback=%s stock=%s%s", field, tostring(target), tostring(ok),
    okR and tostring(back) or "ERR", tostring(DM_STOCK[field]), ok and "" or (" err=" .. tostring(err))))
  if WatchDmRefresh then WatchDmRefresh() end -- the hit event carries the damage inputs
end

-- Classic keeps the stock values. Runs at each Classic match start. Stock values come from the class default
-- object; DM_STOCK is the fallback. EndlessIterationNoGoBreaks is skipped when testing is on (the Go Break test owns it).
-- Also clears the endless-add and endless-promote overrides. Each game call is in pcall.
function ClassicStockRestore()
  local dm = DifficultyManager()
  if not dm then print("[Reforged] classic stock restore: no difficulty manager"); return end
  local cdo, source = nil, "cdo"
  local okC, c = pcall(function() return dm:GetClass():GetCDO() end)
  if okC and c then cdo = c else source = "stock" end
  local checked, changed = 0, 0
  for _, k in ipairs(DM_FIELDS) do
    if not (k == "EndlessIterationNoGoBreaks" and TESTING) then
      local stock = nil
      if cdo then
        local okS, sv = pcall(function() return cdo[k] end)
        if okS then stock = sv end
      end
      if stock == nil then stock = DM_STOCK[k] end
      if stock ~= nil then
        checked = checked + 1
        local okR, live = pcall(function() return dm[k] end)
        if not okR then live = nil end
        if live ~= stock then
          local okW, errW = pcall(function() dm[k] = stock end)
          if okW then changed = changed + 1
          else print("[Reforged] classic stock restore: " .. k .. " write failed err=" .. tostring(errW)) end
        end
      end
    end
  end
  local addWas, promoteWas = endlessAddOverride, endlessPromoteOverride
  endlessAddOverride = nil
  endlessPromoteOverride = nil
  print(string.format("[Reforged] classic stock restore changed=%d fields=%d add=%s promote=%s source=%s",
    changed, checked, tostring(addWas), tostring(promoteWas), source))
  WatchEmit("classic-stock", { changed = changed, fields = checked, add = addWas == nil and WatchNull or addWas,
    promote = promoteWas == nil and WatchNull or promoteWas, source = source })
end

-- The three Endless modifiers, for the playable event. Read in pcall. Returns nil when there is no manager.
function DmEndlessRead()
  local dm = DifficultyManager()
  if not dm then return nil end
  local okH, h = pcall(function() return dm.EndlessHealthModifier end)
  local okS, s = pcall(function() return dm.EndlessMovementSpeedModifier end)
  local okD, d = pcall(function() return dm.EndlessDamageModifier end)
  return { health = okH and h or nil, speed = okS and s or nil, damage = okD and d or nil }
end

-- dm-list <field> read|set <key> <value>|remove <key>|stock: reads and writes the two TMap<int32,float>
-- fields of the difficulty manager from Lua. Each write first saves the whole map in DM_LIST_STOCK, once per field.
-- Every UE4SS call runs in pcall. Whether ForEach, Add, Remove and Empty work in this build is unmeasured until a run.
do
  DM_LIST_STOCK = DM_LIST_STOCK or {}
  local DM_LIST_FIELDS = { "HealthAdditionPerWaveList", "CrowdControlModifierPerWaveList" }
  local function ListValue(x)
    if type(x) == "table" or type(x) == "userdata" then
      local okG, r = pcall(function() return x:get() end)
      if okG then return r end
    end
    return x
  end
  -- Returns the sorted { k, v } rows of a map, or nil and the error.
  local function ListRows(map)
    local rows = {}
    local ok, err = pcall(function()
      map:ForEach(function(k, v) rows[#rows + 1] = { k = ListValue(k), v = ListValue(v) } end)
      table.sort(rows, function(a, b) return a.k < b.k end)
    end)
    if not ok then return nil, err end
    return rows
  end
  local function ListText(rows)
    local parts = {}
    for _, r in ipairs(rows) do parts[#parts + 1] = tostring(r.k) .. "=" .. tostring(r.v) end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  local function ListPrint(field, rows, err)
    if not rows then print("[Reforged] dm-list " .. field .. " read failed err=" .. tostring(err)); return end
    print(string.format("[Reforged] dm-list %s read n=%d %s", field, #rows, ListText(rows)))
  end
  local function ListMap(field)
    local dm = DifficultyManager()
    if not dm then return nil, "no difficulty manager" end
    local ok, map = pcall(function() return dm[field] end)
    if not ok or map == nil then return nil, "field read failed err=" .. tostring(map) end
    return map
  end

  function DmListRun(field, op, a2, a3)
    local known = field == DM_LIST_FIELDS[1] or field == DM_LIST_FIELDS[2]
    if not known then print("dm-list rejected: field must be HealthAdditionPerWaveList or CrowdControlModifierPerWaveList"); return end
    if op ~= "read" and op ~= "set" and op ~= "remove" and op ~= "stock" then
      print("[Reforged] dm-list rejected: use read, set <key> <value>, remove <key> or stock"); return
    end
    local map, mapErr = ListMap(field)
    if not map then print("[Reforged] dm-list " .. field .. " " .. op .. " failed: " .. tostring(mapErr)); return end

    if op == "read" then
      local rows, err = ListRows(map)
      ListPrint(field, rows, err)
      WatchEmit("dmlist", { field = field, op = op, ok = rows ~= nil, n = rows and #rows or nil })
      return
    end

    -- Writes: save the stock copy first (set and remove only). Refuse to write when the map cannot be read.
    local before, beforeErr = ListRows(map)
    if not before then
      print("[Reforged] dm-list " .. field .. " " .. op .. " failed: cannot read before change err=" .. tostring(beforeErr)); return
    end
    if op ~= "stock" and DM_LIST_STOCK[field] == nil then DM_LIST_STOCK[field] = before end

    if op == "set" then
      local key, value = tonumber(a2), tonumber(a3)
      if not key or not value then print("[Reforged] dm-list rejected: set needs a number key and a number value"); return end
      local okA, errA = pcall(function() map:Add(key, value) end)
      local rows, rowsErr = ListRows(map)
      local readback = nil
      if rows then
        for _, r in ipairs(rows) do if r.k == key then readback = r.v end end
      end
      print(string.format("[Reforged] dm-list %s set %s=%s ok=%s readback=%s err=%s", field, tostring(key), tostring(value),
        tostring(okA), tostring(readback), okA and "none" or tostring(errA)))
      ListPrint(field, rows, rowsErr)
      WatchEmit("dmlist", { field = field, op = op, key = key, value = value, ok = okA, n = rows and #rows or nil })
    elseif op == "remove" then
      local key = tonumber(a2)
      if not key then print("[Reforged] dm-list rejected: remove needs a number key"); return end
      local okR, errR = pcall(function() map:Remove(key) end)
      if not okR then print(string.format("[Reforged] dm-list %s remove %s ok=false err=%s", field, tostring(key), tostring(errR))) end
      local rows, rowsErr = ListRows(map)
      ListPrint(field, rows, rowsErr)
      WatchEmit("dmlist", { field = field, op = op, key = key, ok = okR, n = rows and #rows or nil })
    else -- stock
      local saved = DM_LIST_STOCK[field]
      if not saved then print("[Reforged] dm-list " .. field .. " stock failed: no saved copy"); return end
      local okS, errS = pcall(function()
        map:Empty()
        for _, r in ipairs(saved) do map:Add(r.k, r.v) end
      end)
      if not okS then print("[Reforged] dm-list " .. field .. " stock ok=false err=" .. tostring(errS)) end
      local rows, rowsErr = ListRows(map)
      ListPrint(field, rows, rowsErr)
      WatchEmit("dmlist", { field = field, op = op, ok = okS, n = rows and #rows or nil })
    end
  end

  -- Reforged scaling curves. The `curve` command and the curve settings rows set CURVE_WANT. CurveApplyAll writes the
  -- Difficulty Manager from a stock copy saved at the first change, so repeats do not compound. Defaults (scale 1, no cap)
  -- write nothing. Health, damage and speed multiply the stock step. CC: 1 - (1 - v) x scale. A cap freezes the multiplier:
  -- the base takes the value of the round before the cap, and the steps go to 0 (CurveCapCheck). Globals, to keep the main chunk small.
  CURVE_NAMES = { health = true, damage = true, speed = true, cc = true }
  CURVE_CAP_NAMES = { "health", "damage", "speed" }
  CURVE_STEP = { health = "EndlessHealthAdditionPerWave", damage = "EndlessDamageAdditionPerWave", speed = "EndlessMovementSpeedAdditionPerWave" }
  CURVE_BASE = { health = "EndlessHealthModifier", damage = "EndlessDamageModifier", speed = "EndlessMovementSpeedModifier" }
  CURVE_LIST = { health = "HealthAdditionPerWaveList", cc = "CrowdControlModifierPerWaveList" }
  CURVE_STATE = CURVE_STATE or { touched = false, frozen = {}, M = nil, warned = false }
  CURVE_STOCK = CURVE_STOCK or nil
  function CurveWantDefault()
    CURVE_WANT = {
      health = { scale = 1.0, cap = nil }, damage = { scale = 1.0, cap = nil },
      speed = { scale = 1.0, cap = nil }, cc = { scale = 1.0, cap = nil } }
  end
  CurveWantDefault()
  function CurveFmt(x)
    if type(x) == "number" then return string.format("%.6g", x) end
    return tostring(x)
  end
  function CurveAnyNonDefault()
    for _, name in ipairs({ "health", "damage", "speed", "cc" }) do
      if CURVE_WANT[name].scale ~= 1 or CURVE_WANT[name].cap ~= nil then return true end
    end
    return false
  end
  function CurveGet(dm, field)
    local ok, v = pcall(function() return dm[field] end)
    if ok and type(v) == "number" then return v end
    return nil
  end
  function CurveSetField(dm, field, v)
    local ok, err = pcall(function() dm[field] = v end)
    local okR, back = pcall(function() return dm[field] end)
    print(string.format("[Reforged] curve write %s=%s set=%s readback=%s%s", field, CurveFmt(v), tostring(ok),
      okR and CurveFmt(back) or "ERR", ok and "" or (" err=" .. tostring(err))))
    return ok
  end
  function CurveWriteList(field, rows)
    local map = ListMap(field)
    if not map then print("[Reforged] curve write " .. field .. " failed: no difficulty manager"); return false end
    local okE = pcall(function() map:Empty() end)
    local okA = okE
    for _, r in ipairs(rows) do
      if not pcall(function() map:Add(r.k, r.v) end) then okA = false end
    end
    local back, backErr = ListRows(map)
    print(string.format("[Reforged] curve write %s n=%d %s ok=%s", field, back and #back or 0,
      back and ListText(back) or ("read failed err=" .. tostring(backErr)), tostring(okA)))
    return okA
  end
  -- Saves the stock values once. Returns false when one of them cannot be read: nothing is written then.
  function CurveStockSave(dm)
    if CURVE_STOCK then return true end
    local st = { step = {}, base = {}, list = {} }
    for _, name in ipairs(CURVE_CAP_NAMES) do
      st.step[name] = CurveGet(dm, CURVE_STEP[name])
      st.base[name] = CurveGet(dm, CURVE_BASE[name])
      if st.step[name] == nil or st.base[name] == nil then
        print("[Reforged] curve failed: cannot read stock " .. name); return false
      end
    end
    for _, name in ipairs({ "health", "cc" }) do
      local map = ListMap(CURVE_LIST[name])
      local rows, err = nil, "no difficulty manager"
      if map then rows, err = ListRows(map) end
      if not rows then print("[Reforged] curve failed: cannot read stock list " .. name .. " err=" .. tostring(err)); return false end
      st.list[name] = rows
    end
    CURVE_STOCK = st
    print("[Reforged] curve stock saved health=" .. CurveFmt(st.step.health) .. " damage=" .. CurveFmt(st.step.damage)
      .. " speed=" .. CurveFmt(st.step.speed) .. " list=" .. ListText(st.list.health) .. " cc=" .. ListText(st.list.cc))
    return true
  end
  -- The step at absolute wave i: the last list key at or below i, else the scalar step. rows are sorted by key.
  function CurveStepAt(rows, scalar, i)
    local step = scalar
    for _, row in ipairs(rows) do
      if row.k <= i then step = row.v end
    end
    return step
  end
  -- The multiplier at round r from the current values. Health sums the steps of waves M+1..r. Damage and speed: base + step x k.
  function CurveMultAt(dm, name, M, r)
    local base = CurveGet(dm, CURVE_BASE[name])
    local step = CurveGet(dm, CURVE_STEP[name])
    if base == nil or step == nil then return nil end
    if name == "health" then
      local map = ListMap(CURVE_LIST.health)
      local rows = map and ListRows(map)
      if not rows then return nil end
      local h = base
      for i = M + 1, r do h = h + CurveStepAt(rows, step, i) end
      return h
    end
    return base + step * math.max(0, r - M)
  end
  -- Applies the wanted values from the stock copy. A frozen base goes back to stock first.
  function CurveApplyAll()
    local dm = DifficultyManager()
    if not dm then print("[Reforged] curve: no difficulty manager"); return false end
    if not CurveAnyNonDefault() and CURVE_STATE.touched ~= true then return true end
    if not CurveStockSave(dm) then return false end
    for _, name in ipairs(CURVE_CAP_NAMES) do
      if CURVE_STATE.frozen[name] then
        CurveSetField(dm, CURVE_BASE[name], CURVE_STOCK.base[name])
        CURVE_STATE.frozen[name] = nil
      end
    end
    local w, st = CURVE_WANT, CURVE_STOCK
    CurveSetField(dm, CURVE_STEP.health, st.step.health * w.health.scale)
    CurveSetField(dm, CURVE_STEP.damage, st.step.damage * w.damage.scale)
    CurveSetField(dm, CURVE_STEP.speed, st.step.speed * w.speed.scale)
    local hRows, cRows = {}, {}
    for i, r in ipairs(st.list.health) do hRows[i] = { k = r.k, v = r.v * w.health.scale } end
    for i, r in ipairs(st.list.cc) do cRows[i] = { k = r.k, v = 1 - (1 - r.v) * w.cc.scale } end
    CurveWriteList(CURVE_LIST.health, hRows)
    CurveWriteList(CURVE_LIST.cc, cRows)
    CURVE_STATE.touched = CurveAnyNonDefault()
    print(string.format("[Reforged] curve applied health=%s damage=%s speed=%s cc=%s cap=%s/%s/%s", CurveFmt(w.health.scale),
      CurveFmt(w.damage.scale), CurveFmt(w.speed.scale), CurveFmt(w.cc.scale), CurveFmt(w.health.cap or "none"),
      CurveFmt(w.damage.cap or "none"), CurveFmt(w.speed.cap or "none")))
    return true
  end
  -- Freezes one multiplier when its value at round r reaches the cap. Round r keeps the value of round r-1.
  function CurveCapCheck(dm, name, r)
    local cap = CURVE_WANT[name].cap
    local now = CurveMultAt(dm, name, CURVE_STATE.M, r)
    local prev = CurveMultAt(dm, name, CURVE_STATE.M, r - 1)
    if now == nil or prev == nil then print("[Reforged] curve " .. name .. " cap check failed: cannot read round " .. r); return end
    if now < cap then return end
    local rows = nil
    if name == "health" then
      local map = ListMap(CURVE_LIST.health)
      rows = map and ListRows(map)
      if not rows then print("[Reforged] curve health cap failed: cannot read list"); return end
    end
    CurveSetField(dm, CURVE_BASE[name], prev)
    CurveSetField(dm, CURVE_STEP[name], 0)
    if rows then
      local zero = {}
      for i, row in ipairs(rows) do zero[i] = { k = row.k, v = 0 } end
      CurveWriteList(CURVE_LIST.health, zero)
    end
    CURVE_STATE.frozen[name] = true
    print(string.format("[Reforged] curve %s capped at round %d: value %s reaches cap %s, base frozen at %s, steps 0",
      name, r, CurveFmt(now), CurveFmt(cap), CurveFmt(prev)))
  end
  -- Called once per round build (ReforgedBuildRound), after the round is counted and before its calls.
  -- M = the round before the first build that reads Endless iteration 1 (inferred from the static note). No growth before M.
  function CurveRoundCheck(r)
    if CURVE_STATE.M == nil then
      local it = tonumber(EndlessIteration())
      if it ~= nil and it >= 1 then
        CURVE_STATE.M = r - 1
        print(string.format("[Reforged] curve M=%d (first build with iteration %d at round %d)", CURVE_STATE.M, it, r))
      end
    end
    local dm = nil
    for _, name in ipairs(CURVE_CAP_NAMES) do
      if CURVE_WANT[name].cap ~= nil and not CURVE_STATE.frozen[name] then
        if CURVE_STATE.M == nil then
          if not CURVE_STATE.warned then
            CURVE_STATE.warned = true
            print("[Reforged] curve cap skipped: M unknown (iteration 0), no growth yet")
          end
        else
          dm = dm or DifficultyManager()
          if dm then CurveCapCheck(dm, name, r) end
        end
      end
    end
  end
  function CurveMapReset()
    CURVE_STATE.M = nil
    CURVE_STATE.warned = false
  end
  -- Classic and Manual: restore stock when the mod changed a curve. The file rows set the wanted values again in Reforged.
  function CurveRestoreIfChanged()
    if CURVE_STATE.touched ~= true then return end
    CurveWantDefault()
    CurveApplyAll()
    print("[Reforged] curve stock restored: not Reforged")
  end
  function CurveStatus()
    local dm = DifficultyManager()
    local w = CURVE_WANT
    for _, name in ipairs({ "health", "damage", "speed", "cc" }) do
      local parts = { "[Reforged] curve " .. name .. " scale=" .. CurveFmt(w[name].scale) }
      if name ~= "cc" then
        parts[#parts + 1] = "cap=" .. (w[name].cap and CurveFmt(w[name].cap) or "none")
        if dm then
          parts[#parts + 1] = "step=" .. CurveFmt(CurveGet(dm, CURVE_STEP[name])) .. " base=" .. CurveFmt(CurveGet(dm, CURVE_BASE[name]))
        end
      end
      if name == "health" or name == "cc" then
        local map = dm and ListMap(CURVE_LIST[name])
        local rows = map and ListRows(map)
        parts[#parts + 1] = "list=" .. (rows and ListText(rows) or "?")
      end
      print(table.concat(parts, " "))
    end
    local frozen = {}
    for _, name in ipairs(CURVE_CAP_NAMES) do if CURVE_STATE.frozen[name] then frozen[#frozen + 1] = name end end
    print("[Reforged] curve state touched=" .. tostring(CURVE_STATE.touched) .. " M=" .. tostring(CURVE_STATE.M)
      .. " frozen=" .. (#frozen > 0 and table.concat(frozen, ",") or "none"))
  end
  -- curve status | curve stock | curve <name> stock | curve <name> <scale 0..3> | curve <name> cap <value >= 1 | none>
  function CurveCommand(a, b, c)
    if a == nil or a == "" or a == "status" then CurveStatus(); return end
    if a == "stock" then
      CurveWantDefault()
      CurveApplyAll()
      return
    end
    if not CURVE_NAMES[a] then print("[Reforged] curve rejected: name must be health, damage, speed or cc"); return end
    if b == "stock" then
      CURVE_WANT[a] = { scale = 1.0, cap = nil }
    elseif b == "cap" then
      if a == "cc" then print("[Reforged] curve rejected: cc has no cap"); return end
      if c == "none" then
        CURVE_WANT[a].cap = nil
      else
        local v = c and tonumber(c)
        if not v or v < 1 then print("[Reforged] curve rejected: cap needs a number >= 1, or none"); return end
        CURVE_WANT[a].cap = v
      end
    else
      local s = b and tonumber(b)
      if not s or s < 0 or s > 3 then print("[Reforged] curve rejected: scale needs a number from 0 to 3"); return end
      CURVE_WANT[a].scale = s
    end
    CurveApplyAll()
    CurveStatus()
  end
end

-- Damage probe. Logs the BaseDamage of ApplyDamage-family calls. dmgCalls is read with `dmg-read`.
-- The hooks are registered only by `dmg-probe on`. Every crash today followed `testing on`. Symbolized UE4SS
-- frames show Lua touching a game object that may be gone. Cause inferred. The causer is not read; every call counts under "?".
local dmgCalls = { n = 0, byCauser = {}, on = false }
local function DmgHook(path, baseIdx)
  local ok, err = SafeRegisterHook(path, function(self, ...)
    if not TESTING then return end
    local a = { ... }
    local v = a[baseIdx]
    local base = nil
    if type(v) == "number" then base = v
    elseif v ~= nil then local o, r = pcall(function() return v:get() end); if o then base = tonumber(r) end end
    local causer = "?"
    dmgCalls.n = dmgCalls.n + 1
    local rec = dmgCalls.byCauser[causer]
    if not rec then rec = { n = 0, lo = math.huge, hi = -math.huge }; dmgCalls.byCauser[causer] = rec end
    rec.n = rec.n + 1
    if base then if base < rec.lo then rec.lo = base end; if base > rec.hi then rec.hi = base end end
    if dmgCalls.n <= 15 then print(string.format("[Reforged] damage %s base=%s causer=%s", path:match(":(.*)$"), tostring(base), causer)) end
  end)
  print("[Reforged] damage hook " .. path .. " registered=" .. tostring(ok) .. " " .. tostring(err))
end
-- dmg-probe on: registers the three damage hooks once. A second call registers nothing.
function DmgProbeOn()
  if dmgCalls.on then print("[Reforged] dmg-probe already on"); return end
  dmgCalls.on = true
  DmgHook("/Script/OMD.OMDGameplayStatics:ApplyDamage", 2)
  DmgHook("/Script/OMD.OMDGameplayStatics:ApplyPointDamage", 2)
  DmgHook("/Script/OMD.OMDGameplayStatics:ApplyRadialDamage", 2)
end
local function DmgRead()
  local parts = {}
  for causer, r in pairs(dmgCalls.byCauser) do parts[#parts + 1] = string.format("%s n=%d base=%.1f..%.1f", causer, r.n, r.lo, r.hi) end
  table.sort(parts)
  print(string.format("[Reforged] dmg-read iter=%s calls=%d %s", EndlessIteration(), dmgCalls.n, table.concat(parts, " | ")))
end

-- feign off/on: turn the player's Feign Death movement ability off or on, so enemies can (or cannot) target the player.
local function FeignSet(on)
  local pc, pawn
  pcall(function() pc = FindFirstOf("OMDPlayerController") end)
  if pc and pc:IsValid() then pcall(function() pawn = pc.Pawn end) end
  if not pawn or not pawn:IsValid() then print("[Reforged] feign-set failed: player pawn unavailable"); return end
  local ok, err = pcall(function() pawn:Server_SetMoveAbilityActive(on) end)
  local after = "?"
  pcall(function() after = pawn.bMoveAbilityActive end)
  print(string.format("[Reforged] feign-set requested=%s call=%s active=%s err=%s", tostring(on), tostring(ok), tostring(after), tostring(err)))
end
-- coordinator-class: log the live coordinator's class and path, so the map's selected coordinator is visible at runtime.
local function CoordinatorClass()
  local c = coordinator()
  if not c then print("[Reforged] coordinator-class: no coordinator"); return end
  local cls = "?"
  pcall(function() cls = c:GetClass():GetFullName() end)
  print("[Reforged] coordinator-class object=" .. tostring(c:GetFullName()) .. " class=" .. tostring(cls))
end
-- Read-only status line for the game-master panel, printed every 4 s while a coordinator exists. The panel reads it from the log,
-- so the dashboard needs no command. One line, fixed key=value fields.
local function PanelStatus()
  local c = coordinator()
  if not c then return end
  local function num(fn) local ok, v = pcall(fn); return ok and tostring(v) or "?" end
  local dm = DifficultyManager()
  local gs = nil
  pcall(function() gs = FindFirstOf("OMDGameState") end)
  local alive = num(function() return c:GetNumPawnsAlive() end)
  local waiting = num(function() return c:GetNumPawnsWaitingForSpawn() end)
  local approved = num(function() return c:GetNumPawnsApprovedForSpawn() end)
  local rift = num(function() return c.RiftPoints end)
  local goBreak = "?"
  if gs and gs:IsValid() then goBreak = num(function() return gs.bIsGoBreakActive end) end
  local function dmv(k) if not dm then return "?" end return num(function() return dm[k] end) end
  -- The HUD reads wave, rift and score from OMDGameState, not from the coordinator (coordinator.RiftPoints stayed at the kept value while the HUD fell).
  local function gsv(k) if not (gs and gs:IsValid()) then return "?" end return num(function() return gs[k] end) end
  -- Every live non-Wisp pawn, director-spawned ones included: the coordinator's alive count misses those. protos= is name:count pairs for the panel.
  local live, byProto = 0, {}
  for _, e in ipairs(LiveNonWispAI()) do
    live = live + 1
    local okP, pn = pcall(function() return e.actor:GetProtoName():ToString() end)
    pn = okP and tostring(pn):gsub("[^%w_]", "") or "unknown"
    byProto[pn] = (byProto[pn] or 0) + 1
  end
  local parts = {}
  for k, v in pairs(byProto) do parts[#parts + 1] = k .. ":" .. v end
  table.sort(parts)
  local hoardReleased, hoardReason = HoardReleased()
  print(string.format("[Reforged] panel-status mode=%s testing=%s iter=%s alive=%s waiting=%s approved=%s rift=%s riftTarget=%s goBreakActive=%s noGoBreaks=%s health=%s speed=%s damage=%s wave=%s gsIter=%s gsRift=%s score=%s live=%d protos=%s hoard=%s held=%d",
    tostring(ENDLESS_MODE), tostring(TESTING), EndlessIteration(), alive, waiting, approved, rift, tostring(RIFT_TARGET), goBreak, dmv("EndlessIterationNoGoBreaks"),
    dmv("EndlessHealthModifier"), dmv("EndlessMovementSpeedModifier"), dmv("EndlessDamageModifier"),
    gsv("CurrentWave"), gsv("EndlessIteration"), gsv("RiftPoints"), gsv("TotalScore"), live, #parts > 0 and table.concat(parts, ",") or "-",
    hoardReleased and "released" or tostring(hoardReason), #HOARD_HELD))
end
GameLoop(4000, function() PanelStatus(); return false end)

-- Perf sampler. `perf on` samples the world delta seconds every 100 ms and prints one `perf` line per second.
-- The sampler only reads game values. `perf-class <Name>` adds a class to PERF_EXTRA: the first entry is the proj= count,
-- each later entry adds an x_<Name>= field. The loops stay registered; their bodies do nothing while perf is off.
-- lastReal and lastFrames: GetRealTimeSeconds and GetFrameCount at the last tick. noteFrames: the no-GetFrameCount note is printed.
PERF = { on = false, lite = false, lastWave = nil, gameplayStatics = nil, kismet = nil, lastReal = nil, lastFrames = nil, noteFrames = false, lastPawns = {} }
PERF_EXTRA = { "ProjectileMovementComponent" }
-- Counts valid objects of a class. nil from FindAllOf means no object of that class: 0. A failed call: "?".
local function PerfCount(className)
  local ok, n = pcall(function()
    local list = FindAllOf(className)
    local k = 0
    if list then for _, o in ipairs(list) do if o:IsValid() then k = k + 1 end end end
    return k
  end)
  return ok and tostring(n) or "?"
end
local function PerfWisp()
  local ok, n = pcall(function()
    local list = FindAllOf("OMDAICharacter")
    local k = 0
    if list then for _, a in ipairs(list) do if a:IsValid() and a:GetFullName():find("BP_Wisp_") then k = k + 1 end end end
    return k
  end)
  return ok and tostring(n) or "?"
end
local function PerfWave()
  local ok, v = pcall(function()
    local gs = FindFirstOf("OMDGameState")
    if not gs or not gs:IsValid() then return "?" end
    return tostring(gs.CurrentWave)
  end)
  return ok and v or "?"
end
local function PerfMax(t) if #t == 0 then return "?" end local m = t[1] for _, v in ipairs(t) do if v > m then m = v end end return string.format("%.1f", m) end
local function PerfMean(t) if #t == 0 then return "?" end local s = 0 for _, v in ipairs(t) do s = s + v end return string.format("%.1f", s / #t) end
-- One line when the wave changed since the last perf line.
local function PerfRound(wave, iter, live)
  local hs, ss = {}, {}
  for _, e in ipairs(live) do
    local okH, mh = pcall(function() return e.actor:GetMaxHealth() end)
    if okH and tonumber(mh) then hs[#hs + 1] = tonumber(mh) end
    local okS, sp = pcall(function() return e.actor.CharacterMovement.MaxWalkSpeed end)
    if okS and tonumber(sp) then ss[#ss + 1] = tonumber(sp) end
  end
  print(string.format("[Reforged] perf-round wave=%s iter=%s n=%s healthMax=%s healthMean=%s speedMax=%s speedMean=%s",
    wave, iter, tostring(#live), PerfMax(hs), PerfMean(hs), PerfMax(ss), PerfMean(ss)))
end
-- Pawn-drop logger. PERF.lastPawns maps each live non-Wisp pawn's full name to {class, x, y, z} from the previous tick.
-- When PAWN_DROP_MIN or more of those names are missing from the new list, print one line. The sample uses the last known location.
PAWN_DROP_MIN = 5
-- PawnRead: one location read and one health read for a pawn. Called once per pawn in PerfTick.
-- state: origin when the location read failed or all of |x|, |y|, |z| are below 1.0; dead when health reads and is <= 0;
-- active for the rest. The result keeps the location, so PawnDropCheck does not read it again.
local function PawnRead(e)
  local r = { x = 0, y = 0, z = 0, locOk = false, hp = nil }
  local okL, loc = pcall(function() return e.actor:K2_GetActorLocation() end)
  if okL and loc then
    local okV, vx, vy, vz = pcall(function() return loc.X, loc.Y, loc.Z end)
    if okV and tonumber(vx) and tonumber(vy) and tonumber(vz) then
      r.x, r.y, r.z, r.locOk = vx, vy, vz, true
    end
  end
  local okH, h = pcall(function() return e.actor:GetHealth() end)
  if okH and tonumber(h) then r.hp = tonumber(h) end
  if not r.locOk or (math.abs(r.x) < 1.0 and math.abs(r.y) < 1.0 and math.abs(r.z) < 1.0) then
    r.state = "origin"
  elseif r.hp ~= nil and r.hp <= 0 then
    r.state = "dead"
  else
    r.state = "active"
  end
  return r
end
local function PawnDropCheck(live, reads)
  local now = {}
  for i, e in ipairs(live) do
    local r = reads[i]
    now[e.full] = { class = e.full:match("^(%S+)") or "?", x = r.x, y = r.y, z = r.z, state = r.state, hp = r.hp }
  end
  local last = PERF.lastPawns or {}
  local gone = {}
  for name in pairs(last) do
    if now[name] == nil then gone[#gone + 1] = name end
  end
  if #gone >= PAWN_DROP_MIN then
    table.sort(gone)
    local counts = {}
    for _, name in ipairs(gone) do
      local cls = last[name].class
      counts[cls] = (counts[cls] or 0) + 1
    end
    local classNames = {}
    for cls in pairs(counts) do classNames[#classNames + 1] = cls end
    table.sort(classNames)
    local parts = {}
    for _, cls in ipairs(classNames) do parts[#parts + 1] = cls .. ":" .. counts[cls] end
    local states = { active = 0, dead = 0, origin = 0 }
    for _, name in ipairs(gone) do
      local st = last[name].state or "active"
      states[st] = (states[st] or 0) + 1
    end
    local samples = {}
    for i = 1, math.min(3, #gone) do
      local rec = last[gone[i]]
      samples[#samples + 1] = string.format("%s@%.0f,%.0f,%.0f hp=%s", gone[i], rec.x, rec.y, rec.z,
        rec.hp ~= nil and string.format("%g", rec.hp) or "?")
    end
    print(string.format("[Reforged] pawn-drop n=%d classes=%s active=%d dead=%d origin=%d sample=%s", #gone, table.concat(parts, ","),
      states.active, states.dead, states.origin, table.concat(samples, "; ")))
  end
  PERF.lastPawns = now
end
-- PerfTick runs once a second, in one ExecuteInGameThread call. It reads GetWorldDeltaSeconds once a second,
-- so dtMax is the largest of those one-per-second reads, not of the 100 ms reads that the old sampler took.
-- dtMean: when GetFrameCount and GetRealTimeSeconds both read, (real ms since the last tick) / (frames since the last tick).
-- Without GetFrameCount, the one delta read is the only sample.
local function PerfKismet()
  if PERF.kismet == nil then
    local okK, o = pcall(StaticFindObject, "/Script/Engine.Default__KismetSystemLibrary")
    if okK and o then PERF.kismet = o end
  end
  return PERF.kismet
end
local function PerfFrameCount()
  local k = PerfKismet()
  if not k then return nil end
  local ok, n = pcall(function() return k:GetFrameCount() end)
  if ok and tonumber(n) then return tonumber(n) end
  return nil
end
local function PerfRealSeconds(c)
  local ok, t = pcall(function() return PERF.gameplayStatics:GetRealTimeSeconds(c) end)
  if ok and tonumber(t) then return tonumber(t) end
  return nil
end
-- Frame-time helper for both perf modes. Reads GetWorldDeltaSeconds, GetRealTimeSeconds and GetFrameCount for coordinator c.
-- Returns dtMean, dtMax and samples. Updates PERF.lastReal and PERF.lastFrames. A field, not a local: the main chunk is at its local limit.
function PERF.dt(c)
  -- The GameplayStatics object is cached after the first find.
  if c and not PERF.gameplayStatics then
    local okF, o = pcall(StaticFindObject, "/Script/Engine.Default__GameplayStatics")
    if okF and o then PERF.gameplayStatics = o end
  end
  local dtMs, real, frames
  if c and PERF.gameplayStatics then
    local ok, dt = pcall(function() return PERF.gameplayStatics:GetWorldDeltaSeconds(c) end)
    if ok and tonumber(dt) then dtMs = tonumber(dt) * 1000 end
    real = PerfRealSeconds(c)
    frames = PerfFrameCount()
  end
  local dtMean, dtMax, samples = "?", "?", 0
  if dtMs then dtMax = string.format("%.1f", dtMs) end
  if frames and real and PERF.lastFrames and PERF.lastReal and frames > PERF.lastFrames then
    samples = frames - PERF.lastFrames
    dtMean = string.format("%.1f", (real - PERF.lastReal) * 1000 / samples)
  elseif dtMs and not (frames and real) then
    if frames == nil and not PERF.noteFrames then
      PERF.noteFrames = true
      print("[Reforged] perf: GetFrameCount unavailable, dtMean is one sample per second")
    end
    dtMean = string.format("%.1f", dtMs)
    samples = 1
  end
  if frames and real then PERF.lastFrames = frames; PERF.lastReal = real end
  return dtMean, dtMax, samples
end
local function PerfTick()
  local wave = PerfWave()
  local iter = EndlessIteration()
  -- Lite mode: frame time only. No pawn reads and no round tracking.
  if PERF.lite then
    local dtMean, dtMax, samples = PERF.dt(coordinator())
    print(string.format("[Reforged] perf t=%s wave=%s iter=%s dtMean=%s dtMax=%s samples=%s mode=lite",
      tostring(os.time()), wave, iter, dtMean, dtMax, tostring(samples)))
    return
  end
  local live = LiveNonWispAI()
  if wave ~= "?" then
    if PERF.lastWave ~= nil and wave ~= PERF.lastWave then PerfRound(wave, iter, live) end
    PERF.lastWave = wave
  end
  local dtMean, dtMax, samples = PERF.dt(coordinator())
  local counts = {}
  for _, e in ipairs(live) do
    local cls = e.full:match("^(%S+)") or "?"
    counts[cls] = (counts[cls] or 0) + 1
  end
  local names = {}
  for cls in pairs(counts) do names[#names + 1] = cls end
  table.sort(names)
  local parts = {}
  for _, cls in ipairs(names) do parts[#parts + 1] = cls .. ":" .. counts[cls] end
  local classes = #parts > 0 and table.concat(parts, ",") or "-"
  local proj = PERF_EXTRA[1] and PerfCount(PERF_EXTRA[1]) or "0"
  local extras = {}
  for i = 2, #PERF_EXTRA do extras[#extras + 1] = " x_" .. PERF_EXTRA[i] .. "=" .. PerfCount(PERF_EXTRA[i]) end
  -- One read per pawn for location and health. The same reads feed the state counts and PawnDropCheck.
  local reads, states = {}, { active = 0, dead = 0, origin = 0 }
  for i, e in ipairs(live) do
    local r = PawnRead(e)
    reads[i] = r
    states[r.state] = states[r.state] + 1
  end
  print(string.format("[Reforged] perf t=%s wave=%s iter=%s dtMean=%s dtMax=%s samples=%s live=%s active=%d dead=%d origin=%d wisp=%s proj=%s classes=%s%s mode=full",
    tostring(os.time()), wave, iter, dtMean, dtMax, tostring(samples), tostring(#live), states.active, states.dead, states.origin,
    PerfWisp(), proj, classes, table.concat(extras)))
  PawnDropCheck(live, reads)
end
-- One game-thread call a second, only while perf is on.
GameLoop(1000, function() if PERF.on then PerfTick() end; return false end)

-- route-prefer first|second|stock: set every fork on the map (a path point with two or more successors) so orcs take the first
-- branch, the second branch, or the stock weights again. The stock weights are remembered the first time a fork is changed.
-- Measured on Colosseum: weights 100/0 sent every sampled orc to the chosen branch. Maps with no fork report forks=0.
ROUTE_STOCK = ROUTE_STOCK or {}
local function RoutePrefer(mode)
  local forks = 0
  for _, p in ipairs(RoutePoints()) do
    pcall(function()
      local np = p.NextPoints
      local okN, n = pcall(function() return #np end)
      if not okN or not n or n < 2 or n > 6 then return end
      forks = forks + 1
      for i = 1, n do
        local br = np[i]
        local key = tostring(p.PointIndex) .. ":" .. tostring(br.PointIndex)
        if ROUTE_STOCK[key] == nil then ROUTE_STOCK[key] = br.BranchWeight end
        if mode == "stock" then br.BranchWeight = ROUTE_STOCK[key]
        else br.BranchWeight = ((mode == "first" and i == 1) or (mode == "second" and i == 2)) and 100 or 0 end
      end
    end)
  end
  print(string.format("[Reforged] route-prefer %s forks=%d", mode, forks))
end

-- Loot goblin: a Kobold that pays out small coins when it takes damage. Coins in this game are a player currency
-- (OMDPlayerController:GiveCoin), so a hit gives the player GOBLIN_COINS coins and shows the gold flyoff above the goblin.
-- Damage is seen as a drop of the goblin's Health between two 250 ms ticks. Several hits in one tick pay once.
GOBLIN_COINS = 3
GOBLIN_COIN_METHOD = "AddCoin" -- OMDPlayerController method used to pay: GiveCoin, AddCoin or Server_GiveCoin (set with `coin-give <method> <n>`)
local goblins = {}
-- Registers one new Kobold pawn as a loot goblin. The door sampler calls it for each new pawn of a door call.
-- A pawn registers once: the set is keyed by its full name. Returns false when it is already registered.
do
  local registered = {}
  RegisterGoblinPawn = function(e)
    if registered[e.full] then return false end
    registered[e.full] = true
    local ok, h = pcall(function() return e.actor:GetHealth() end)
    goblins[#goblins + 1] = { actor = e.actor, full = e.full, health = ok and tonumber(h) or nil }
    print(string.format("[Reforged] loot-goblin registered %s health=%s", ShortName(e.full), tostring(ok and h or "?")))
    return true
  end
end
local function GoblinPlayerCoin()
  local pc
  pcall(function() pc = FindFirstOf("OMDPlayerController") end)
  if not pc or not pc:IsValid() then return nil end
  local ok, c = pcall(function() return pc:GetCoin() end)
  return pc, ok and tonumber(c) or nil
end
local function GoblinPay(g, drop)
  local pc, before = GoblinPlayerCoin()
  if not pc then print("[Reforged] loot-goblin hit: no player controller"); return end
  local okG, errG = pcall(function() pc[GOBLIN_COIN_METHOD](pc, GOBLIN_COINS) end)
  local _, after = GoblinPlayerCoin()
  -- Log-only read, runs on any map (AfterAny).
  AfterAny(700, function() ExecuteInGameThread(function() local _, later = GoblinPlayerCoin(); print("[Reforged] loot-goblin coin 0.7 s later: " .. tostring(later)) end) end)
  local okF = pcall(function() g.actor:Multicast_SpawnCoinFlyoff(GOBLIN_COINS) end)
  print(string.format("[Reforged] loot-goblin hit %s health -%.1f coins +%d (player coin %s -> %s) give=%s flyoff=%s%s",
    ShortName(g.full), drop, GOBLIN_COINS, tostring(before), tostring(after), tostring(okG), tostring(okF), okG and "" or (" err=" .. tostring(errG))))
end
local function GoblinTick()
  for i = #goblins, 1, -1 do
    local g = goblins[i]
    local okV, valid = pcall(function() return g.actor:IsValid() end)
    if not okV or not valid then
      print("[Reforged] loot-goblin gone " .. ShortName(g.full)); table.remove(goblins, i)
    else
      local ok, h = pcall(function() return g.actor:GetHealth() end)
      h = ok and tonumber(h) or nil
      if h and g.health and h < g.health - 0.01 then GoblinPay(g, g.health - h) end   -- a hit that reaches zero pays too
      if h then g.health = h end
    end
  end
end
GameLoop(250, function() if #goblins > 0 then GoblinTick() end; return false end)

-- pawn-strip: developer toggle. While on, a 2 s loop turns off ticking on each live non-Wisp pawn's
-- FXMesh, Skeleton and Decal components. PAWN_STRIPPED holds the full names of the pawns already done.
-- The in-game effect is unmeasured until a UE4SS.log line measures it.
if PAWN_STRIP == nil then PAWN_STRIP = false end
if PAWN_STRIPPED == nil then PAWN_STRIPPED = {} end
local PAWN_STRIP_FIELDS = { "FXMesh", "Skeleton", "Decal" }

-- Returns the valid component objects of one pawn. Each read is in a pcall. Nil and invalid values are skipped.
local function PawnStripComponents(actor)
  local comps = {}
  for _, field in ipairs(PAWN_STRIP_FIELDS) do
    local okF, c = pcall(function() return actor[field] end)
    if okF and c ~= nil then
      local okV, valid = pcall(function() return c:IsValid() end)
      if okV and valid then comps[#comps + 1] = c end
    end
  end
  return comps
end

-- Sets tick on each component of one pawn. Returns the count of calls that worked and the count that failed.
local function PawnStripSetTick(actor, enable)
  local ok, fail = 0, 0
  for _, c in ipairs(PawnStripComponents(actor)) do
    if pcall(function() c:SetComponentTickEnabled(enable) end) then ok = ok + 1 else fail = fail + 1 end
  end
  return ok, fail
end

-- Runs on the game thread, once per loop pass while PAWN_STRIP is on. Skips pawns already in PAWN_STRIPPED.
local function PawnStripPass()
  if not PAWN_STRIP then return end
  local newCount, ok, fail = 0, 0, 0
  for _, e in ipairs(LiveNonWispAI()) do
    if not PAWN_STRIPPED[e.full] then
      local o, f = PawnStripSetTick(e.actor, false)
      ok, fail = ok + o, fail + f
      PAWN_STRIPPED[e.full] = true
      newCount = newCount + 1
    end
  end
  if newCount > 0 then
    local total = 0
    for _ in pairs(PAWN_STRIPPED) do total = total + 1 end
    print(string.format("[Reforged] pawn-strip applied new=%d total=%d ok=%d fail=%d", newCount, total, ok, fail))
  end
end
GameLoop(2000, function()
  if PAWN_STRIP then PawnStripPass() end
  return false
end)

-- Runs on the game thread. Turns tick back on for each live pawn in PAWN_STRIPPED, then clears PAWN_STRIPPED.
local function PawnStripRestore()
  local pawns, ok, fail = 0, 0, 0
  for _, e in ipairs(LiveNonWispAI()) do
    if PAWN_STRIPPED[e.full] then
      pawns = pawns + 1
      local o, f = PawnStripSetTick(e.actor, true)
      ok, fail = ok + o, fail + f
    end
  end
  PAWN_STRIPPED = {}
  print(string.format("[Reforged] pawn-strip restored n=%d ok=%d fail=%d", pawns, ok, fail))
end

-- pawn-collide: developer toggle. While PAWN_COLLIDE_OFF is true (pawn-collide off), a 2 s loop sets
-- the response to the Pawn channel (channel 2) to ECR_Ignore (0) on each live non-Wisp pawn's capsule, so enemy
-- capsules ignore each other. pawn-collide on sets it back to ECR_Block (2). PAWN_COLLIDE_DONE holds the full names
-- of the pawns already done.
-- The in-game effect is unmeasured until a UE4SS.log line measures it.
-- Reason: the OMDMinionCharacter profile has object type Pawn and does not override the Pawn channel, so enemy
-- capsules block each other (DefaultEngine.ini).
if PAWN_COLLIDE_OFF == nil then PAWN_COLLIDE_OFF = false end
if PAWN_COLLIDE_DONE == nil then PAWN_COLLIDE_DONE = {} end

-- Returns the capsule of one pawn, or nil. Each read is in a pcall. Nil and invalid values give nil.
local function PawnCollideCapsule(actor)
  local okC, c = pcall(function() return actor.CapsuleComponent end)
  if okC and c ~= nil then
    local okV, valid = pcall(function() return c:IsValid() end)
    if okV and valid then return c end
  end
  return nil
end

-- Sets the response to the Pawn channel on one capsule. Returns true if the call works, else false.
local function PawnCollideSetResponse(capsule, response)
  return (pcall(function() capsule:SetCollisionResponseToChannel(2, response) end))
end

-- Runs on the game thread, once per loop pass while PAWN_COLLIDE_OFF is true. Skips pawns already in PAWN_COLLIDE_DONE.
local function PawnCollidePass()
  if not PAWN_COLLIDE_OFF then return end
  local newCount, ok, fail = 0, 0, 0
  for _, e in ipairs(LiveNonWispAI()) do
    if not PAWN_COLLIDE_DONE[e.full] then
      if PawnCollideSetResponse(PawnCollideCapsule(e.actor), 0) then ok = ok + 1 else fail = fail + 1 end
      PAWN_COLLIDE_DONE[e.full] = true
      newCount = newCount + 1
    end
  end
  if newCount > 0 then
    local total = 0
    for _ in pairs(PAWN_COLLIDE_DONE) do total = total + 1 end
    print(string.format("[Reforged] pawn-collide applied new=%d total=%d ok=%d fail=%d", newCount, total, ok, fail))
  end
end
GameLoop(2000, function()
  if PAWN_COLLIDE_OFF then PawnCollidePass() end
  return false
end)

-- Runs on the game thread. Sets ECR_Block (2) on the capsule of each live pawn in PAWN_COLLIDE_DONE, then clears it.
local function PawnCollideRestore()
  local pawns, ok, fail = 0, 0, 0
  for _, e in ipairs(LiveNonWispAI()) do
    if PAWN_COLLIDE_DONE[e.full] then
      pawns = pawns + 1
      if PawnCollideSetResponse(PawnCollideCapsule(e.actor), 2) then ok = ok + 1 else fail = fail + 1 end
    end
  end
  PAWN_COLLIDE_DONE = {}
  print(string.format("[Reforged] pawn-collide restored n=%d ok=%d fail=%d", pawns, ok, fail))
end

-- Developer commands: rejected unless TESTING is on.
local DEV_OPS = {}
for _, v in ipairs({ "class-props", "probe", "sweep", "feign", "distinct", "profile-run", "profile-stop",
  "goblin-status", "goblin-coins", "goblin-hit", "coin-give", "spawn-center", "stat-sample", "tally", "tally-reset", "behavior", "bt-probe", "bt-probe-load", "ai-perf", "cvar", "pawn-flags", "pawn-strip", "pawn-collide", "coord-spawn-pos", "coord-queue", "proto-pass", "anchor-boot", "anchor-hold", "anchor-hold-mode", "anchor-release", "anchor-status", "anchor-health", "anchor-auto", "anchor-min-dist", "cspawn", "play-list", "queue-block", "tick-hold", "spawn-pace", "reforged-plan", "reforged-round", "reforged-round-next", "modifier", "dmg-probe", "break-mode", "break-order", "break-gate", "preview", "dm-list", "hurt-player", "wisp-probe", "wisp-clear", "moneybags-kill", "curve", "difficulty", "banner", "rift-move", "look", "walk", "push", "watch-hits" }) do DEV_OPS[v] = true end

local function SetTesting(on)
  if on and not TESTING then
    local c = coordinator()
    local gs
    pcall(function() gs = FindFirstOf("OMDGameState") end)
    local savedCoordinator, savedGameState
    if c then pcall(function() savedCoordinator = c.RiftPoints end) end
    if gs then pcall(function() if gs:IsValid() then savedGameState = gs.RiftPoints end end) end
    TESTING_SAVED_RIFT = { coordinator = savedCoordinator, gameState = savedGameState }
  end
  TESTING = on
  if on then
    -- No hook registration here. The DIAG hooks are registered at load; their bodies check TESTING.
    if autoTestMapReady then
      BreaksOff()
    end
  else
    -- The keeper ran only when rift-target set a value. Restore the saved points only then.
    local keeperRan = RIFT_TARGET ~= nil
    RIFT_TARGET = nil
    -- SPAWN_CENTER stays as it is: it is the under-floor spawn fix, not a testing feature.
    if TESTING_SAVED_RIFT and keeperRan then
      local c = coordinator()
      local gs
      pcall(function() gs = FindFirstOf("OMDGameState") end)
      if c and TESTING_SAVED_RIFT.coordinator ~= nil then pcall(function() c.RiftPoints = TESTING_SAVED_RIFT.coordinator end) end
      if gs and gs:IsValid() and TESTING_SAVED_RIFT.gameState ~= nil then pcall(function() gs.RiftPoints = TESTING_SAVED_RIFT.gameState end) end
    end
    TESTING_SAVED_RIFT = nil
    local stock = DM_STOCK.EndlessIterationNoGoBreaks
    if stock ~= nil then
      local dm = DifficultyManager()
      if dm then pcall(function() dm.EndlessIterationNoGoBreaks = stock end) end
    end
    if WAVE_HOLD.on then
      local c = coordinator()
      if c and WAVE_HOLD.stock ~= nil then pcall(function() c.DefaultWaveTimer = WAVE_HOLD.stock end) end
      WAVE_HOLD.on = false
      print("[Reforged] wave-hold off: testing mode is off")
    end
    if DIAG_STARTED then print("[Reforged] testing off: diagnostic hooks stay registered until the game restarts") end
  end
  print("[Reforged] testing=" .. tostring(TESTING) .. " riftTarget=" .. tostring(RIFT_TARGET))
end

-- Test mode. F7 in the Endless hub calls this. On: the rift keeper holds 1000 rift points and SetTesting(true) runs,
-- but TESTING_LIGHT keeps Feign Death and the diagnostic hooks off. Off: SetTesting(false) runs, which clears RIFT_TARGET.
-- TEST_MODE is off at every launch. It is not saved to a file.
function TestModeSet(on, source)
  on = on == true
  if on then
    TESTING_LIGHT = true
    local okT, errT = pcall(SetTesting, true)
    if not okT then print("[Reforged] test-mode SetTesting err=" .. tostring(errT)) end
    RIFT_TARGET = 1000
    TEST_MODE = true
  else
    local okT, errT = pcall(SetTesting, false)
    if not okT then print("[Reforged] test-mode SetTesting err=" .. tostring(errT)) end
    TESTING_LIGHT = false
    TEST_MODE = false
  end
  print(string.format("[Reforged] test-mode on=%s source=%s", tostring(on), tostring(source)))
  WatchEmit("test-mode", { on = on, source = tostring(source) })
  pcall(SetModeText, ReadEndlessMode())
end

-- ai-perf: reads and writes the AI performance fields on the game instance (AIMovementComponentMaxSkippedFrames,
-- AILerpmeshSpeed, AIOverlapPerfMode, AITargetingEnabled) and the coordinator field MaxAICharacters.
-- Developer command. Each write is read back. Only the offline check runs here; the in-game effect is unmeasured.
local AI_PERF_REJECT = "[Reforged] command rejected: ai-perf needs read, stock, skipframes 0-16, lerpmesh 0-100, overlap on|off, targeting on|off, or maxai 1-10000"
local AI_PERF_FIELDS = {
  skipframes = { field = "AIMovementComponentMaxSkippedFrames", coordinator = false },
  lerpmesh = { field = "AILerpmeshSpeed", coordinator = false },
  overlap = { field = "AIOverlapPerfMode", coordinator = false },
  targeting = { field = "AITargetingEnabled", coordinator = false },
  maxai = { field = "MaxAICharacters", coordinator = true },
}
local function AiPerfValid(o)
  if not o then return false end
  local ok, v = pcall(function() return o:IsValid() end)
  return ok and v == true
end
local function AiPerfInstance()
  local gi
  pcall(function() gi = FindFirstOf("BP_OMDGameInstance_C") end)
  if not AiPerfValid(gi) then pcall(function() gi = FindFirstOf("OMDGameInstance") end) end
  if AiPerfValid(gi) then return gi end
  return nil
end
local function AiPerfRead(obj, field)
  if not obj then return "?" end
  local ok, v = pcall(function() return obj[field] end)
  if not ok or v == nil then return "?" end
  return tostring(v)
end
-- Runs on the game thread. Callers wrap it in ExecuteInGameThread (AiPerfWrite), or batch several in one (ai-perf stock).
local function AiPerfSet(setting, value)
  local spec = AI_PERF_FIELDS[setting]
  local obj
  if spec.coordinator then obj = coordinator() else obj = AiPerfInstance() end
  if not obj then
    print("[Reforged] ai-perf " .. setting .. " unavailable: no " .. (spec.coordinator and "coordinator" or "game instance"))
    return
  end
  local was = AiPerfRead(obj, spec.field)
  local ok = pcall(function() obj[spec.field] = value end)
  print(string.format("[Reforged] ai-perf %s was=%s now=%s ok=%s", setting, was, AiPerfRead(obj, spec.field), tostring(ok)))
end
local function AiPerfWrite(setting, value)
  ExecuteInGameThread(function() AiPerfSet(setting, value) end)
end
local function AiPerf(line)
  local words = {}
  for w in line:gmatch("%S+") do words[#words + 1] = w end
  local sub, val, extra = words[2], words[3], words[4]
  if extra ~= nil or sub == nil then print(AI_PERF_REJECT); return end
  if sub == "read" and val == nil then
    ExecuteInGameThread(function()
      local gi = AiPerfInstance()
      print(string.format("[Reforged] ai-perf skipFrames=%s lerpMesh=%s overlap=%s targeting=%s maxAI=%s",
        AiPerfRead(gi, "AIMovementComponentMaxSkippedFrames"), AiPerfRead(gi, "AILerpmeshSpeed"),
        AiPerfRead(gi, "AIOverlapPerfMode"), AiPerfRead(gi, "AITargetingEnabled"),
        AiPerfRead(coordinator(), "MaxAICharacters")))
    end)
  elseif sub == "stock" and val == nil then
    -- One game-thread call for all five writes. Each write still prints its own was=/now=/ok= line.
    ExecuteInGameThread(function()
      AiPerfSet("skipframes", 0)
      AiPerfSet("lerpmesh", 0.0)
      AiPerfSet("overlap", false)
      AiPerfSet("targeting", true)
      AiPerfSet("maxai", 10000)
    end)
  elseif sub == "skipframes" and val and val:match("^%d+$") and tonumber(val) <= 16 then
    AiPerfWrite("skipframes", math.floor(tonumber(val)))
  elseif sub == "lerpmesh" and val and val:match("^%d+%.?%d*$") and tonumber(val) <= 100 then
    AiPerfWrite("lerpmesh", tonumber(val) + 0.0)
  elseif (sub == "overlap" or sub == "targeting") and (val == "on" or val == "off") then
    AiPerfWrite(sub, val == "on")
  elseif sub == "maxai" and val and val:match("^%d+$") and tonumber(val) >= 1 and tonumber(val) <= 10000 then
    AiPerfWrite("maxai", math.floor(tonumber(val)))
  else
    print(AI_PERF_REJECT)
  end
end

-- cvar <name> <value>: runs "<name> <value>" as a console command through KismetSystemLibrary.
-- Developer command. Runs on the game thread. The fake test world has no KismetSystemLibrary, so ok=false there.
-- ConsoleExec(text): runs one console command through KismetSystemLibrary. Returns ok, errText ("-" when ok).
-- Global, not local: the main chunk is at its local limit. Game thread only. Used by cvar and by custom_map.lua (#93 M2).
function ConsoleExec(text)
  local okRun, res = pcall(function()
    local k = PerfKismet()
    if not k then error("no KismetSystemLibrary", 0) end
    local ctx = coordinator() or FindFirstOf("PlayerController")
    if not ctx then error("no world context", 0) end
    return k:ExecuteConsoleCommand(ctx, text, nil)
  end)
  local ok = okRun and res ~= false
  return ok, okRun and "-" or tostring(res)
end

local function CvarRun(name, value)
  local ok, errText = ConsoleExec(name .. " " .. value)
  print(string.format("[Reforged] cvar %s=%s ok=%s err=%s", name, value, tostring(ok), errText))
end

-- pawn-flags [n]: reads animation and optimization flags on up to n live non-Wisp pawns.
-- Each read has its own pcall. A failed read prints ?.
local function FlagText(fn)
  local ok, v = pcall(fn)
  if ok and v ~= nil then return tostring(v) end
  return "?"
end

local function PawnFlags(arg)
  local n = 20
  if arg ~= "" then
    n = tonumber(arg)
    if not n or n % 1 ~= 0 or n < 1 or n > 50 then
      print("[Reforged] command rejected: pawn-flags [1-50]")
      return
    end
  end
  ExecuteInGameThread(function()
    local live = LiveNonWispAI()
    local count, budgeted, uro = 0, 0, 0
    local ticks, tickOrder = {}, {}
    for i = 1, math.min(n, #live) do
      local a = live[i].actor
      local mesh = nil
      pcall(function() mesh = a.Mesh end)
      local cls = FlagText(function() return a:GetFName():ToString() end)
      local bud = FlagText(function() return a.MeshBudgeted end)
      local opt = FlagText(function() return a.Optimized end)
      local nav = FlagText(function() return a.OptimizedNavWalking end)
      local uroText = FlagText(function() return mesh.bEnableUpdateRateOptimizations end)
      local anim = FlagText(function() return mesh.VisibilityBasedAnimTickOption end)
      local meshTick = FlagText(function() return mesh.PrimaryComponentTick.TickInterval end)
      local moveTick = FlagText(function() return a.CharacterMovement.PrimaryComponentTick.TickInterval end)
      count = count + 1
      if bud == "true" then budgeted = budgeted + 1 end
      if uroText == "true" then uro = uro + 1 end
      if not ticks[anim] then ticks[anim] = 0; tickOrder[#tickOrder + 1] = anim end
      ticks[anim] = ticks[anim] + 1
      print(string.format("[Reforged] pawn-flags #%d class=%s budgeted=%s optimized=%s optNav=%s uro=%s animTick=%s meshTick=%s moveTick=%s",
        i, cls, bud, opt, nav, uroText, anim, meshTick, moveTick))
    end
    local parts = {}
    for _, v in ipairs(tickOrder) do parts[#parts + 1] = v .. ":" .. ticks[v] end
    print(string.format("[Reforged] pawn-flags summary n=%d budgeted=%d/%d uro=%d/%d animTick=%s",
      count, budgeted, count, uro, count, table.concat(parts, ",")))
  end)
end

-- Anchor and counted spawns (option B). Developer commands; see Mods/Reforged/README.md "Anchor and counted spawns".
-- ANCHOR: the held pawn that keeps the director wave counted. ANCHOR_SPAWNS: counted spawns made from the director.
ANCHOR = nil
ANCHOR_SPAWNS = 0
ANCHOR_AUTO = false
ANCHOR_AUTO_GEN = 0
ANCHOR_BOOTING = false
ANCHOR_HOLD_MODE = "tree" -- anchor-hold-mode tree|brain|dilation. See HoldAnchor.
ANCHOR_KEEP_COLLISION = true -- True keeps the anchor collision on (the stuck probe needs it). false turns it off at hold.
ANCHOR_STUCK_DELAY = 1000000.0 -- seconds written to the controller stuck timeout (ReforgedStuckDelay, offset 0x650) at hold.

do
local function ErrStr(e)
  local ok, s = pcall(tostring, e)
  if ok then return s end
  return "?"
end

-- Runs one anchor command. An error becomes one log line; the command never raises.
function SafeRun(label, fn, ...)
  local ok, err = pcall(fn, ...)
  if not ok then print("[Reforged] " .. label .. " error=" .. ErrStr(err)) end
end

-- Object name of a full name, the same id the watch stream uses (for example OrcMedium_1).
local function PawnObjName(full)
  if full == nil then return nil end
  return full:match("%.([^%.%s]+)$") or full
end

-- A set anchor is usable only while it is valid and not dead. Anything else is stale.
local function AnchorValid()
  if ANCHOR == nil then return false end
  local okV, v = pcall(function() return ANCHOR:IsValid() end)
  if not okV or v ~= true then return false end
  return not PawnIsDead(ANCHOR)
end

-- Clears a set anchor that is no longer usable. Returns true when it cleared one.
local function ClearStaleAnchor()
  if ANCHOR == nil or AnchorValid() then return false end
  print("[Reforged] anchor stale, cleared")
  ANCHOR = nil
  ANCHOR_SPAWNS = 0
  return true
end

local function AnchorName()
  if ANCHOR == nil then return "none" end
  local ok, full = pcall(function() return ANCHOR:GetFullName() end)
  if ok and full then return PawnObjName(full) end
  return "unreadable"
end

-- Live, non-Wisp, counted pawns that are not dead. Each entry is { actor = , full = }.
function CountedStanding()
  local found = {}
  for _, e in ipairs(LiveNonWispAI()) do
    local okC, counted = pcall(IsCountedPawn, e.actor)
    if okC and counted == true and not PawnIsDead(e.actor) then found[#found + 1] = e end
  end
  return found
end

-- First counted standing pawn whose object name is not in snap. Returns the entry and its name, or nil.
local function NewCounted(snap)
  for _, e in ipairs(CountedStanding()) do
    local name = PawnObjName(e.full)
    if not snap[name] then return e, name end
  end
  return nil
end

-- Boot: turns one door spawner on until a counted pawn appears (20 s at most), then makes that pawn the anchor.
-- ANCHOR_BOOTING is true from the start of a boot until it succeeds, times out or fails.
function AnchorBoot(doorIndex)
  if ANCHOR_BOOTING then
    print("[Reforged] anchor-boot rejected: a boot is running")
    return
  end
  if ANCHOR ~= nil then
    if AnchorValid() then
      print("[Reforged] anchor-boot rejected: an anchor exists (anchor-release first)")
      return
    end
    ClearStaleAnchor()
  end
  ANCHOR_BOOTING = true
  ExecuteInGameThread(function()
    local sp, okSaved, saved, done = nil, false, nil, false
    local function Restore()
      if not sp then return end
      if okSaved then
        pcall(function() sp.bIsActive = saved end)
      else
        print("[Reforged] anchor-boot warning: saved bIsActive unreadable, spawner left on")
      end
    end
    local function EndBoot()
      done = true
      ANCHOR_BOOTING = false
    end
    local function Fail(text)
      Restore()
      EndBoot()
      print(text)
    end
    local okInit, errInit = pcall(function()
      local okS, found = pcall(FindSpawnerByIndex, doorIndex)
      if not okS or not found then
        EndBoot()
        print("[Reforged] anchor-boot rejected: no spawner for door " .. tostring(doorIndex))
        return
      end
      sp = found
      local snap = {}
      for _, e in ipairs(CountedStanding()) do snap[PawnObjName(e.full)] = true end
      local okSv, sv = pcall(function() return sp.bIsActive end)
      okSaved, saved = okSv, sv
      local okOn = pcall(function() sp.bIsActive = true end)
      if not okOn then
        EndBoot()
        print("[Reforged] anchor-boot rejected: cannot turn spawner " .. tostring(doorIndex) .. " on")
        return
      end
      print("[Reforged] anchor-boot door=" .. tostring(doorIndex) .. " spawner on")

      local phase, ticks = "wait", 0
      local foundName, slipTicks, slipped, seen = nil, 0, 0, {}
      GameLoop(500, function()
        if done then return true end
        do
          local function gtBody()
            if done then return end
            local okStep, errStep = pcall(function()
              if phase == "wait" then
                ticks = ticks + 1
                local okF, e, name = pcall(NewCounted, snap)
                if okF and e then
                  ANCHOR = e.actor
                  foundName = name
                  local okP, proto = pcall(function() return e.actor:GetProtoName():ToString() end)
                  local foundProto = okP and tostring(proto) or "?"
                  Restore()
                  ANCHOR_BOOTING = false
                  print(string.format("[Reforged] anchor-boot ok pawn=%s proto=%s after=%.1fs",
                    tostring(name), foundProto, ticks * 0.5))
                  phase = "slip"
                elseif ticks >= 40 then
                  Restore()
                  EndBoot()
                  print("[Reforged] anchor-boot timeout door=" .. tostring(doorIndex))
                  WatchEmit("anchor", { phase = "boot", ok = false, id = WatchNull, door = doorIndex, slipped = 0 })
                end
              elseif phase == "slip" then
                slipTicks = slipTicks + 1
                local okL, list = pcall(CountedStanding)
                if okL and list then
                  for _, e in ipairs(list) do
                    local name = PawnObjName(e.full)
                    if not snap[name] and name ~= foundName and not seen[name] then
                      seen[name] = true
                      slipped = slipped + 1
                    end
                  end
                end
                if slipTicks >= 4 then
                  EndBoot()
                  print("[Reforged] anchor-boot slipped=" .. tostring(slipped))
                  WatchEmit("anchor", { phase = "boot", ok = true, id = foundName or WatchNull, door = doorIndex, slipped = slipped })
                end
              end
            end)
            if not okStep then Fail("[Reforged] anchor-boot error=" .. ErrStr(errStep)) end
          end
          gtBody()
        end
        return false
      end)
    end)
    if not okInit then Fail("[Reforged] anchor-boot error=" .. ErrStr(errInit)) end
  end)
end

-- Stuck timeout. The controller's stuck timer fires after +0x650 seconds (20.0 by default). Registered at load.
do
  local okT = PropertyTypes ~= nil and PropertyTypes.FloatProperty ~= nil
  local okR = false
  if okT then
    okR = pcall(RegisterCustomProperty, {
      Name = "ReforgedStuckDelay", Type = PropertyTypes.FloatProperty,
      BelongsToClass = "/Script/OMD.OMDAIController", OffsetInternal = 0x650,
    })
  end
  print("[Reforged] anchor stuck-delay registered=" .. tostring(okR))
end

-- Queue block properties. ReforgedSpawnKey is the spawner key at +0x3ec; ReforgedHold is the tick hold byte at +0x3f4.
do
  local okK, okH = false, false
  if PropertyTypes ~= nil and PropertyTypes.IntProperty ~= nil then
    okK = pcall(RegisterCustomProperty, {
      Name = "ReforgedSpawnKey", Type = PropertyTypes.IntProperty,
      BelongsToClass = "/Script/OMD.OMDOnslaughtCoordinator", OffsetInternal = 0x3ec,
    })
  end
  if PropertyTypes ~= nil and PropertyTypes.ByteProperty ~= nil then
    okH = pcall(RegisterCustomProperty, {
      Name = "ReforgedHold", Type = PropertyTypes.ByteProperty,
      BelongsToClass = "/Script/OMD.OMDOnslaughtCoordinator", OffsetInternal = 0x3f4,
    })
  end
  print("[Reforged] queue-block registered key=" .. tostring(okK) .. " hold=" .. tostring(okH))
end

-- Object helpers for the hold. Each one reads a UObject with pcall and returns nil or false when it cannot.
local function ObjValid(o)
  if o == nil then return false end
  local okV, v = pcall(function() return o:IsValid() end)
  return okV and v == true
end
local function AnchorAddress(obj)
  if obj == nil then return nil end
  local ok, a = pcall(function() return obj:GetAddress() end)
  if ok then return a end
  return nil
end
-- Reads one field of a controller. nil when the controller is nil or the read fails.
local function CtrlRead(ctrl, field)
  if ctrl == nil then return nil end
  local ok, v = pcall(function() return ctrl[field] end)
  if ok then return v end
  return nil
end
-- The controller whose pawn is ANCHOR, matched by address. nil when none is found.
local function AnchorController()
  local anchorAddr = AnchorAddress(ANCHOR)
  local okL, list = pcall(FindAllOf, "OMDAIController")
  if anchorAddr == nil or not okL or not list then return nil end
  for _, c in ipairs(list) do
    if ObjValid(c) then
      local okP, pawnAddr = pcall(function() return c:K2_GetPawn():GetAddress() end)
      if okP and pawnAddr ~= nil and pawnAddr == anchorAddr then return c end
    end
  end
  return nil
end

-- Death and damage diagnostics. Post-hooks on OMDCharacter (uSDK OMDCharacter.h):
--   BP_ServerDeath(Damage, DamageEvent, eventInstigator, DamageCauser)
--   BP_AnyDamageTaken(Damage, DamageType, DamageCauser, dotDamage)
-- A handler reads what it needs while the hook runs. It keeps no parameter and makes no deferred call.
local anchorHooks = { done = false }
-- True when the hook's context object is ANCHOR. Compares addresses only.
local function IsAnchorContext(ctx)
  if ANCHOR == nil then return false end
  local a = AnchorAddress(ctx)
  return a ~= nil and a == AnchorAddress(ANCHOR)
end
-- Full name of an object, or nil when it is nil or unreadable.
local function FullNameOrNil(obj)
  if obj == nil then return nil end
  local ok, full = pcall(function() return obj:GetFullName() end)
  if ok and full then return tostring(full) end
  return nil
end
local function AnchorDeathHook(ctx, damage, damageEvent, instigator, causer)
  if not IsAnchorContext(ctx) then return end
  local causerName = FullNameOrNil(causer)
  print(string.format("[Reforged] anchor-death dmg=%s causer=%s", tostring(damage), tostring(causerName)))
  WatchEmit("anchor", { phase = "death", dmg = damage or WatchNull, causer = causerName or WatchNull })
end
local function AnchorDamageHook(ctx, damage, damageType, causer, dotDamage)
  if not IsAnchorContext(ctx) then return end
  local causerName = FullNameOrNil(causer)
  local typeName = PawnObjName(FullNameOrNil(damageType))
  print(string.format("[Reforged] anchor-damage dmg=%s causer=%s type=%s",
    tostring(damage), tostring(causerName), tostring(typeName)))
  WatchEmit("anchor", { phase = "damage", dmg = damage or WatchNull, causer = causerName or WatchNull, type = typeName or WatchNull })
end
-- Registers both hooks once, on the first anchor hold. Each registration is pcall-wrapped and printed.
local function AnchorHooksOnce()
  if anchorHooks.done then return end
  anchorHooks.done = true
  local noPre = function() end
  local okD = SafeRegisterHook("/Script/OMD.OMDCharacter:BP_ServerDeath", noPre, AnchorDeathHook)
  local okA = SafeRegisterHook("/Script/OMD.OMDCharacter:BP_AnyDamageTaken", noPre, AnchorDamageHook)
  print("[Reforged] anchor-hooks death registered=" .. tostring(okD) .. " damage registered=" .. tostring(okA))
end

-- Guard. One 1 s loop per hold, while the anchor is valid. In tree mode it re-applies the NoMovement tree
-- when the default tree comes back. It emits phase guard on each change, and at least every 5 s.
local anchorGuard = { gen = 0, ctrl = nil, tree = nil, mode = nil, last = nil, lastEmit = 0 }
local function AnchorGuardTick()
  local g = anchorGuard
  if not AnchorValid() then
    g.gen = g.gen + 1 -- ends the loop on its next tick
    return
  end
  local stuck = CtrlRead(g.ctrl, "bIsStuck")
  local def = CtrlRead(g.ctrl, "bIsRunningDefaultBehavior")
  if g.mode == "tree" and def == true and g.ctrl and g.tree then
    local okT, errT = pcall(function() g.ctrl:SetTempBehavior(g.tree) end)
    local okW = pcall(function() g.ctrl.ReforgedStuckDelay = ANCHOR_STUCK_DELAY end)
    if okT then
      print("[Reforged] anchor-guard reapplied tree (default behavior came back)")
    else
      print("[Reforged] anchor-guard reapply error=" .. ErrStr(errT))
    end
    if not okW then print("[Reforged] anchor-guard stuck-delay write ok=false") end
  end
  local okH, h = pcall(function() return ANCHOR:GetHealth() end)
  local health = okH and h or nil
  local key = tostring(health) .. "|" .. tostring(stuck) .. "|" .. tostring(def)
  local now = os.time()
  if key ~= g.last or now - g.lastEmit >= 5 then
    g.last, g.lastEmit = key, now
    WatchEmit("anchor", {
      phase = "guard",
      health = health == nil and WatchNull or health,
      stuck = stuck == nil and WatchNull or stuck,
      defaultBehavior = def == nil and WatchNull or def,
    })
  end
end
local function AnchorGuardStart(ctrl, tree, mode)
  anchorGuard.gen = anchorGuard.gen + 1
  anchorGuard.ctrl, anchorGuard.tree, anchorGuard.mode = ctrl, tree, mode
  anchorGuard.last, anchorGuard.lastEmit = nil, 0
  local gen = anchorGuard.gen
  GameLoop(1000, function()
    if gen ~= anchorGuard.gen then return true end
    do
      local function gtBody()
        if gen ~= anchorGuard.gen then return end
        SafeRun("anchor-guard", AnchorGuardTick)
      end
      gtBody()
    end
    return false
  end)
end

-- Hold steps for ANCHOR. Always: the invincible settings (cached, then enabled), no damage, hidden, the stuck
-- timeout (stuck-delay), and collision (kept when ANCHOR_KEEP_COLLISION is true).
-- One mode step, from ANCHOR_HOLD_MODE:
--   tree: the anchor's controller runs the NoMovement tree (SetTempBehavior). Falls back to brain, then dilation.
--   brain: the controller's brain stops and its movement stops. Falls back to dilation.
--   dilation: CustomTimeDilation = 0. Live run 2: the anchor died 21-24 s after spawn with this mode.
-- Modes tree and brain never set CustomTimeDilation. One log line per step. Shared by anchor-hold and the anchor capture.
-- The caller checks that ANCHOR is set.
local function HoldAnchor()
  local function Step(label, fn)
    local ok, err = pcall(fn)
    local line = "[Reforged] anchor-hold " .. label .. " ok=" .. tostring(ok)
    if not ok then line = line .. " error=" .. ErrStr(err) end
    print(line)
    return ok
  end
  AnchorHooksOnce()
  local TREE_PATH = "/Game/Proto/Characters/Minions/_Base/AI/BTree_NoMovement.BTree_NoMovement"
  local function FindTree()
    local found = nil
    pcall(function() found = StaticFindObject(TREE_PATH) end)
    return found
  end
  local holdTree = nil
  -- Runs the tree step. Loads the tree once when it is not in memory. Returns true when the tree was found.
  local function TryTree(ctrl)
    local tree = FindTree()
    if not ObjValid(tree) then
      local okL, errL = pcall(LoadAsset, TREE_PATH)
      print("[Reforged] anchor-hold tree load ok=" .. tostring(okL) .. (okL and "" or " error=" .. ErrStr(errL)))
      tree = FindTree()
    end
    if not ObjValid(tree) then
      print("[Reforged] anchor-hold no tree path=" .. TREE_PATH)
      return false
    end
    holdTree = tree
    Step("tree", function() ctrl:SetTempBehavior(tree) end)
    return true
  end

  Step("invincible-cache", function() ANCHOR:CacheInvincibleSettings() end)
  Step("invincible", function() ANCHOR:EnableInvincibleSettings() end)
  Step("damage", function() ANCHOR.bCanBeDamaged = false end)

  local requested = ANCHOR_HOLD_MODE
  local ctrl = nil
  if requested == "tree" or requested == "brain" then
    ctrl = AnchorController()
    if not ctrl then print("[Reforged] anchor-hold no controller") end
  end
  local used = nil
  if requested == "tree" and ctrl and TryTree(ctrl) then used = "tree" end
  if not used and ctrl then
    Step("brain-stop", function() ctrl.BrainComponent:StopLogic("Reforged anchor") end)
    Step("move-stop", function() ctrl:StopMovement() end)
    used = "brain"
  end
  if not used then
    Step("dilation", function() ANCHOR.CustomTimeDilation = 0.0 end)
    used = "dilation"
  end
  print("[Reforged] anchor-hold mode=" .. used .. " (requested " .. requested .. ")")
  -- The stuck timeout is set in every mode. Dilation mode does not use the controller for its mode step.
  local stuckCtrl = ctrl or AnchorController()
  Step("stuck-delay", function()
    if not stuckCtrl then error("no controller") end
    stuckCtrl.ReforgedStuckDelay = ANCHOR_STUCK_DELAY
    print("[Reforged] anchor-hold stuck-delay read=" .. tostring(stuckCtrl.ReforgedStuckDelay))
  end)

  Step("hidden", function() ANCHOR:SetActorHiddenInGame(true) end)
  if ANCHOR_KEEP_COLLISION then
    print("[Reforged] anchor-hold collision kept")
  else
    Step("collision", function() ANCHOR:SetActorEnableCollision(false) end)
  end
  AnchorGuardStart(stuckCtrl, holdTree, used)
  WatchEmit("anchor", { phase = "hold", id = AnchorName() })
end

-- Hold: the anchor-hold command. Rejected when no valid anchor exists.
function AnchorHold()
  if not AnchorValid() then
    print("[Reforged] anchor-hold rejected: no anchor (anchor-boot first)")
    return
  end
  HoldAnchor()
end

-- Distance in units (3D) from an actor to the nearest OMDAISpawner. Returns nil when the actor or every spawner is unreadable.
local function NearestSpawnerDist(actor)
  local okA, a = pcall(function() return actor:K2_GetActorLocation() end)
  if not okA or not a then return nil end
  local okS, spawners = pcall(FindAllOf, "OMDAISpawner")
  if not okS or not spawners then return nil end
  local best = nil
  for _, sp in ipairs(spawners) do
    local okD, d = pcall(function()
      local p = sp:K2_GetActorLocation()
      local dx, dy, dz = p.X - a.X, p.Y - a.Y, p.Z - a.Z
      return math.sqrt(dx * dx + dy * dy + dz * dz)
    end)
    if okD and type(d) == "number" and (best == nil or d < best) then best = d end
  end
  return best
end

-- Anchor capture. AnchorCaptureBegin is called when the takeover would start. It returns true when it holds the takeover
-- back (the capture waits for a counted pawn). It returns false when the takeover goes ahead now.
function AnchorCaptureBegin()
  -- With the queue block on, no native pawn comes, so the capture does not wait for one.
  if QueueBlockActive() then
    if QB_ANCHOR_SKIP_NOTED ~= true then
      QB_ANCHOR_SKIP_NOTED = true
      print("[Reforged] anchor-capture skipped: queue block active")
    end
    return false
  end
  if not ANCHOR_FROM_NATIVE or AnchorValid() then return false end
  anchorCapture = { since = os.time(), combatSince = nil }
  print("[Reforged] anchor-capture waiting for a counted native pawn")
  return true
end

-- Build phase read for the capture: true in the build phase, false in combat, nil when unreadable.
function AnchorBuildPhase()
  local okG, gs = pcall(FindFirstOf, "OMDGameState")
  if not okG or not gs then return nil end
  local okV, v = pcall(function()
    if not gs:IsValid() then return nil end
    return gs.bIsGoBreakActive
  end)
  if okV and type(v) == "boolean" then return v end
  return nil
end

-- Runs on each takeover loop tick while a capture waits. Takes the first counted pawn that stands at least
-- ANCHOR_MIN_DOOR_DIST from every spawner, or times out after ANCHOR_CAPTURE_TIMEOUT seconds of combat with no such pawn.
-- The takeover then runs in both cases. While it waits, it logs the nearest candidate (at most one line per tick).
function AnchorCaptureTick()
  local cap = anchorCapture
  if not cap then return end
  local now = os.time()
  local build = AnchorBuildPhase()
  if build == true then
    cap.combatSince = nil
  elseif build == false and cap.combatSince == nil then
    cap.combatSince = now
  end
  local okL, list = pcall(CountedStanding)
  local pick, pickDist, nearest, nearestDist = nil, nil, nil, nil
  if okL and list then
    for _, e in ipairs(list) do
      local d = NearestSpawnerDist(e.actor)
      if d ~= nil then
        if nearestDist == nil or d < nearestDist then nearest, nearestDist = e, d end
        if pick == nil and d >= ANCHOR_MIN_DOOR_DIST then pick, pickDist = e, d end
      end
    end
  end
  local mode = tostring(takeoverPending)
  if pick then
    ANCHOR = pick.actor
    local name = PawnObjName(pick.full)
    local okP, proto = pcall(function() return pick.actor:GetProtoName():ToString() end)
    HoldAnchor()
    print(string.format("[Reforged] anchor-capture ok pawn=%s proto=%s after=%ds doorDist=%.0f",
      tostring(name), okP and tostring(proto) or "?", now - cap.since, pickDist))
    WatchEmit("anchor", { phase = "capture", ok = true, id = name or WatchNull, doorDist = pickDist })
  elseif cap.combatSince and now - cap.combatSince > ANCHOR_CAPTURE_TIMEOUT then
    print("[Reforged] anchor-capture timeout")
    WatchEmit("anchor", { phase = "capture", ok = false })
  else
    if nearest then
      print(string.format("[Reforged] anchor-capture waiting: nearest candidate %s at %.0f units (need %s)",
        tostring(PawnObjName(nearest.full)), nearestDist, tostring(ANCHOR_MIN_DOOR_DIST)))
    end
    return
  end
  anchorCapture = nil
  takeoverPending = nil
  Takeover(true)
  print("[Reforged] mode=" .. mode .. " takeover requested (level playable)")
end

-- Map ready for a new level: a capture and the anchor from the last level are not valid here.
function AnchorNewMap()
  anchorCapture = nil
  ANCHOR = nil
  ANCHOR_SPAWNS = 0
  QB_ANCHOR_SKIP_NOTED = nil
end

-- Release: destroys the anchor. ANCHOR is cleared only when the destroy did not error and the actor is then
-- invalid or pending kill. Otherwise the anchor is kept. Returns true when it cleared the anchor.
local function ReleaseAnchor()
  local name = AnchorName()
  local okD, err = pcall(function() ANCHOR:K2_DestroyActor() end)
  local line = "[Reforged] anchor-release ok=" .. tostring(okD) .. " pawn=" .. tostring(name)
  if not okD then line = line .. " error=" .. ErrStr(err) end
  print(line)
  local gone = false
  if okD then
    local okV, valid = pcall(function() return ANCHOR:IsValid() end)
    local okK, pending = pcall(function() return ANCHOR:IsPendingKill() end)
    gone = (okV and valid ~= true) or (okK and pending == true)
  end
  if not gone then
    print("[Reforged] anchor-release failed, anchor kept")
    WatchEmit("anchor", { phase = "release", id = name, ok = false })
    return false
  end
  WatchEmit("anchor", { phase = "release", id = name, ok = true })
  ANCHOR = nil
  ANCHOR_SPAWNS = 0
  return true
end

function AnchorRelease()
  if ANCHOR == nil then
    print("[Reforged] anchor-release rejected: no anchor (anchor-boot first)")
    return
  end
  if not AnchorValid() then
    local name = AnchorName()
    ClearStaleAnchor()
    WatchEmit("anchor", { phase = "release", id = name, ok = false, stale = true })
    return
  end
  ReleaseAnchor()
end

-- Counted spawn helpers. A door's StartingPathPoint may not resolve from Lua (live run 6, 2026-10-18).
-- The fallback is the nearest OMDPathPoint to the spawner, within CSPAWN_PATHPOINT_MAX units (3D).
if CSPAWN_PATHPOINT_MAX == nil then CSPAWN_PATHPOINT_MAX = 2500 end
-- Nearest point per door index for the current map. map-ready clears it.
CSPAWN_POINT_CACHE = CSPAWN_POINT_CACHE or {}

-- Nearest OMDPathPoint to base within CSPAWN_PATHPOINT_MAX. Returns { loc, dist, name } or nil.
local function CspawnNearestPoint(base)
  local okF, points = pcall(FindAllOf, "OMDPathPoint")
  if not okF or not points then return nil end
  local best = nil
  for _, point in ipairs(points) do
    pcall(function()
      if not point:IsValid() then return end
      local okL, loc = pcall(function() return point:K2_GetActorLocation() end)
      if not okL or not loc then return end
      local dx, dy, dz = loc.X - base.X, loc.Y - base.Y, loc.Z - base.Z
      local d = math.sqrt(dx * dx + dy * dy + dz * dz)
      if d <= CSPAWN_PATHPOINT_MAX and (best == nil or d < best.dist) then
        local okN, full = pcall(function() return point:GetFullName() end)
        best = { loc = { X = loc.X, Y = loc.Y, Z = loc.Z }, dist = d, name = okN and (PawnObjName(tostring(full)) or tostring(full)) or "?" }
      end
    end)
  end
  return best
end

-- Returns the cached nearest point for this door, or looks one up and caches it. Nil when none is in range.
local function CspawnPickPoint(doorIndex, base)
  local cached = CSPAWN_POINT_CACHE[doorIndex]
  if cached then
    print("[Reforged] cspawn door=" .. tostring(doorIndex) .. " path point cache hit point=" .. tostring(cached.name))
    return cached
  end
  local near = CspawnNearestPoint(base)
  if near then CSPAWN_POINT_CACHE[doorIndex] = near end
  return near
end

-- Counted spawn: one AI proto at one door, sourced from the anchor or from the first counted standing pawn.
function CountedSpawn(doorIndex, protoName, count)
  local src, srcKind = nil, nil
  if AnchorValid() then
    src, srcKind = ANCHOR, "anchor"
  else
    local list = CountedStanding()
    if list[1] then src, srcKind = list[1].actor, "chain" end
  end
  if not src then
    print("[Reforged] cspawn no tracked source (anchor-boot first)")
    return
  end
  local okSp, sp = pcall(FindSpawnerByIndex, doorIndex)
  if not okSp or not sp then
    print("[Reforged] cspawn no spawner for door " .. tostring(doorIndex))
    return
  end
  local okL, base = pcall(function() return sp:K2_GetActorLocation() end)
  if not okL or not base then
    print("[Reforged] cspawn no location for door " .. tostring(doorIndex))
    return
  end
  local c = coordinator()
  if not c then
    print("[Reforged] cspawn no coordinator")
    return
  end
  -- The spawn point is the door's starting path point. The spawner sits behind a closed door in Manual mode.
  local at = "pathpoint"
  local okPP, pointLoc = pcall(function()
    local point = sp.StartingPathPoint:Get()
    if not point then return nil end
    return point:K2_GetActorLocation()
  end)
  if not okPP or not pointLoc then
    local near = CspawnPickPoint(doorIndex, base)
    if near then
      at = string.format("nearest-pathpoint dist=%.0f point=%s", near.dist, near.name)
      pointLoc = near.loc
    else
      at, pointLoc = "spawner", base
      print("[Reforged] cspawn door=" .. tostring(doorIndex) .. " no path point, spawner location used")
    end
  end
  local g = PROTO_BY_NAME[protoName].guid
  local pos = { X = pointLoc.X, Y = pointLoc.Y, Z = pointLoc.Z + 60 }
  local rot = { Pitch = 0, Yaw = 0, Roll = 0 }
  local proto = { Guid = { A = g.A, B = g.B, C = g.C, D = g.D } }
  local out = {}
  local okCall, ret = pcall(function() return c:SpawnEntityForEntity(src, pos, rot, proto, count, false, out) end)
  local n = "?"
  if okCall then
    local okN, v = pcall(function() return out:GetArrayNum() end)
    if not okN then okN, v = pcall(function() return #out end) end
    if okN then n = tostring(v) end
  end
  local result = okCall and tostring(ret) or ("error " .. ErrStr(ret))
  print(string.format("[Reforged] cspawn door=%s proto=%s count=%s source=%s result=%s out=%s at=%s",
    tostring(doorIndex), protoName, tostring(count), srcKind, result, n, at))
  if okCall and ret ~= false then ANCHOR_SPAWNS = ANCHOR_SPAWNS + count end
end

function AnchorStatus()
  print(string.format("[Reforged] anchor-status anchor=%s valid=%s spawns=%s auto=%s counted-standing=%d",
    AnchorName(), tostring(AnchorValid()), tostring(ANCHOR_SPAWNS), ANCHOR_AUTO and "on" or "off", #CountedStanding()))
end

-- Health read for a live test: shows the anchor's health and dead flag without waiting for it to die.
function AnchorHealth()
  local okH, h = pcall(function() return ANCHOR:GetHealth() end)
  local health = okH and tostring(h) or "error"
  local ctrl = AnchorController()
  print(string.format("[Reforged] anchor-health valid=%s health=%s dead=%s stuck=%s defaultBehavior=%s stuckDelay=%s",
    tostring(AnchorValid()), health, tostring(PawnIsDead(ANCHOR)),
    tostring(CtrlRead(ctrl, "bIsStuck")), tostring(CtrlRead(ctrl, "bIsRunningDefaultBehavior")),
    tostring(CtrlRead(ctrl, "ReforgedStuckDelay"))))
end

-- Auto release: after the director spawns, releases the anchor when no counted pawn but the anchor stands for 8 s.
function AnchorAutoStart()
  ANCHOR_AUTO_GEN = ANCHOR_AUTO_GEN + 1
  local gen, quiet = ANCHOR_AUTO_GEN, 0
  GameLoop(1000, function()
    if gen ~= ANCHOR_AUTO_GEN or not ANCHOR_AUTO then return true end
    do
      local function gtBody()
        if gen ~= ANCHOR_AUTO_GEN or not ANCHOR_AUTO then return end
        if not AnchorValid() or ANCHOR_SPAWNS <= 0 then quiet = 0; return end
        local okL, list = pcall(CountedStanding)
        if not okL or not list then return end
        local anchorName = AnchorName()
        local others = 0
        for _, e in ipairs(list) do
          if PawnObjName(e.full) ~= anchorName then others = others + 1 end
        end
        if others > 0 then quiet = 0; return end
        quiet = quiet + 1
        if quiet >= 8 then
          quiet = 0
          print("[Reforged] anchor-auto release: director wave done")
          ReleaseAnchor()
        end
      end
      gtBody()
    end
    return false
  end)
end
end

-- player-path: developer test tool. Moves the player pawn to a spot in front of the enemy path and sets its
-- aggro bit, so enemies can target it. Acts only when TESTING is on (DEV_OPS). It moves the player and sets the aggro
-- bit while on; it does not change other Classic rules. Game calls are pcall'd; the hold loop uses GameLoop.
do
  DEV_OPS["player-path"] = true
  local PP_DRIFT = 200.0
  local PP = { on = false, x = nil, y = nil, z = nil, pawn = nil, teleport = "none", aggro = false, loopRunning = false }

  local function PPValid(o)
    if o == nil then return false end
    local ok, v = pcall(function() return o:IsValid() end)
    return ok and v and true or false
  end

  local function PPSame(a, b)
    if a == nil or b == nil then return false end
    if a == b then return true end
    local okA, na = pcall(function() return a:GetFullName() end)
    local okB, nb = pcall(function() return b:GetFullName() end)
    return okA and okB and na ~= nil and tostring(na) == tostring(nb)
  end

  local function PPPlayerPawn()
    local pc, pawn
    pcall(function() pc = FindFirstOf("OMDPlayerController") end)
    if not PPValid(pc) then return nil end
    pcall(function() pawn = pc.Pawn end)
    if PPValid(pawn) then return pawn end
    return nil
  end

  -- Level name from the game instance. The mission level name is read in game (not yet measured).
  local function PPMapName()
    local gi, name
    pcall(function() gi = FindFirstOf("BP_OMDGameInstance_C") end)
    if PPValid(gi) then
      local okM, v = pcall(function() return gi:GetCurrentMissionLevelName() end)
      if okM and v ~= nil then
        local okS, s = pcall(function() return v:ToString() end)
        name = okS and tostring(s) or tostring(v)
      end
    end
    return name or "unknown"
  end

  -- Default target for a map. Colosseum (Scenario_17) only; other maps need x y z.
  local function PPDefault(name)
    if name:find("Scenario_17", 1, true) then return -1645.0, -400.0, 1600.0 end
    return nil
  end

  local function PPTeleport(pawn, x, y, z)
    local loc = { X = x, Y = y, Z = z }
    local rot = { Pitch = 0.0, Yaw = 90.0, Roll = 0.0 }
    local okT, ret = pcall(function() return pawn:K2_TeleportTo(loc, rot) end)
    if okT and ret ~= false then return "ok" end
    local okF = pcall(function() pawn:K2_SetActorLocation(loc, false, {}, true) end)
    return okF and "fallback" or "failed"
  end

  local function PPAggro(pawn, on)
    return (pcall(function() pawn:SetAllowAggro(on) end))
  end

  local function PPPrint()
    print(string.format("[Reforged] player-path on=%s target=(%s,%s,%s) teleport=%s aggro=%s",
      tostring(PP.on), tostring(PP.x), tostring(PP.y), tostring(PP.z), PP.teleport, tostring(PP.aggro)))
  end

  -- Distance from the pawn to the target, or nil when the location cannot be read.
  local function PPDist(pawn)
    local okL, p = pcall(function() return pawn:K2_GetActorLocation() end)
    if not okL or p == nil then return nil end
    local okV, dx, dy, dz = pcall(function() return p.X - PP.x, p.Y - PP.y, p.Z - PP.z end)
    if not okV then return nil end
    return math.sqrt(dx * dx + dy * dy + dz * dz)
  end

  -- Places the pawn on the target and sets its aggro bit. reason: on, respawn or drift.
  local function PPPlacePawn(pawn, reason)
    PP.teleport = PPTeleport(pawn, PP.x, PP.y, PP.z)
    PP.aggro = PPAggro(pawn, true)
    PP.pawn = pawn
    WatchEmit("player", { on = true, x = PP.x, y = PP.y, z = PP.z, reason = reason })
  end

  local function PPOff()
    local pawn = PP.pawn
    PP.on = false
    PP.pawn = nil
    if PPValid(pawn) then
      PP.aggro = not PPAggro(pawn, false)
    else
      PP.aggro = false
    end
  end

  local function PPLoopStart()
    if PP.loopRunning then return end
    PP.loopRunning = true
    GameLoop(1000, function()
      if not PP.on then PP.loopRunning = false; return true end
      if not TESTING then
        PPOff()
        PPPrint()
        PP.loopRunning = false
        return true
      end
      local pawn = PPPlayerPawn()
      if pawn then
        local dist = PPDist(pawn)
        local reason = nil
        if not PPSame(pawn, PP.pawn) then reason = "respawn"
        elseif dist and dist > PP_DRIFT then reason = "drift" end
        if reason then
          PPPlacePawn(pawn, reason)
          print(string.format("[Reforged] player-path re-placed reason=%s dist=%s", reason,
            dist and string.format("%.0f", dist) or "?"))
        end
      end
      return false
    end)
  end

  local function PPOn(words)
    local x, y, z
    if #words == 5 then
      x, y, z = tonumber(words[3]), tonumber(words[4]), tonumber(words[5])
      if not (x and y and z) then print("[Reforged] command rejected: player-path on [x y z] needs three numbers"); return end
    elseif #words == 2 then
      local name = PPMapName()
      x, y, z = PPDefault(name)
      if not x then print("[Reforged] player-path: no default point for " .. name .. "; give x y z"); return end
    else
      print("[Reforged] command rejected: use player-path on [x y z]")
      return
    end
    local pawn = PPPlayerPawn()
    if not pawn then print("[Reforged] player-path: player pawn unavailable"); return end
    PP.x, PP.y, PP.z = x, y, z
    pcall(function() pawn:Server_SetMoveAbilityActive(false) end)
    PP.on = true
    PPPlacePawn(pawn, "on")
    PPPrint()
    PPLoopStart()
  end

  -- Called from MapReadyFor. A new map resets the tool to off.
  function PlayerPathReset()
    if not PP.on then return end
    PPOff()
    PP.teleport = "none"
    PPPrint()
  end

  -- player-path | player-path on [x y z] | player-path off. Runs on the game thread.
  function PlayerPathCommand(line)
    local words = {}
    for w in tostring(line):gmatch("%S+") do words[#words + 1] = w end
    local arg = words[2]
    if arg == nil then PPPrint()
    elseif arg == "on" then PPOn(words)
    elseif arg == "off" then PPOff(); PPPrint()
    else print("[Reforged] command rejected: use player-path, player-path on [x y z], or player-path off") end
  end
end

-- wisp-probe / wisp-clear. Test only: spawns one wisp at one door for a live probe.
-- Globals only, inside do ... end, so the main chunk gets no new locals. Every game read is in pcall.
-- REFORGED_WISPS: one { actor, door, kind, auto } per spawn. auto is true for a preview wisp. WatchMapReady empties it.
REFORGED_WISPS = REFORGED_WISPS or {}
do
  local WISP_CLASS_PROP = { normal = "WispClass", heavy = "HeavyWispClass", flyer = "FlyerWispClass" }

  -- Rotation quaternion for a yaw in degrees. Yaw only: X and Y are 0.
  local function WispYawQuat(yawDeg)
    local h = math.rad(tonumber(yawDeg) or 0) / 2
    return { X = 0, Y = 0, Z = math.sin(h), W = math.cos(h) }
  end

  -- Nearest OMDPathPoint object to base. No range cap. Returns the object or nil.
  local function WispNearestPoint(base)
    local okF, points = pcall(FindAllOf, "OMDPathPoint")
    if not okF or not points then return nil end
    local best, bestD = nil, nil
    for _, point in ipairs(points) do
      pcall(function()
        if not point:IsValid() then return end
        local p = point:K2_GetActorLocation()
        local dx, dy, dz = p.X - base.X, p.Y - base.Y, p.Z - base.Z
        local d = math.sqrt(dx * dx + dy * dy + dz * dz)
        if bestD == nil or d < bestD then best, bestD = point, d end
      end)
    end
    return best
  end

  -- The spawner's start point for the kind: StartingPathPoint, or StartingFlyerPathPoint for a flyer. Nil when Get() gives nothing.
  local function WispSpawnerPoint(sp, kind)
    local field = (kind == "flyer") and "StartingFlyerPathPoint" or "StartingPathPoint"
    local okG, point = pcall(function() return sp[field]:Get() end)
    if okG and point ~= nil then return point end
    return nil
  end

  -- Calls SetStartPoint on each controller candidate until one call works. Returns true when one did.
  local function WispSetStart(candidates, point)
    local lastErr = nil
    for _, ctrl in ipairs(candidates) do
      local okS, errS = pcall(function() ctrl:SetStartPoint(point) end)
      if okS then return true end
      lastErr = errS
    end
    return false, lastErr
  end

  -- Spawns one wisp at a door. kind: normal, heavy or flyer. auto: true for a preview wisp.
  -- Returns true when the wisp spawned and was recorded. A probe wisp (auto false) prints a line.
  function ReforgedWispSpawn(doorIndex, kind, auto)
    kind = kind or "normal"
    auto = (auto == true)
    local prop = WISP_CLASS_PROP[kind]
    local f = { class = "?", spawned = false, controller = false, startPoint = "none", setStart = false, err = "none" }
    local okAll, errAll = pcall(function()
      local c = coordinator()
      if not c then f.err = "no coordinator"; return end
      local okC, class = pcall(function() return c[prop] end)
      if not okC or class == nil then f.err = "no " .. tostring(prop); return end
      local okN, full = pcall(function() return class:GetFullName() end)
      full = okN and tostring(full) or "?"
      if not auto then print("[Reforged] wisp-probe class=" .. full) end
      f.class = full:match("%.([^%.%s]+)$") or full
      local sp = FindSpawnerByIndex(doorIndex)
      if not sp then f.err = "no spawner"; return end
      local okL, loc = pcall(function() return sp:K2_GetActorLocation() end)
      local okR, rot = pcall(function() return sp:K2_GetActorRotation() end)
      if not okL or not loc or not okR or not rot then f.err = "spawner transform"; return end
      local transform = { Rotation = WispYawQuat(rot.Yaw), Translation = { X = loc.X, Y = loc.Y, Z = loc.Z }, Scale3D = { X = 1, Y = 1, Z = 1 } }
      local gs = nil
      local okB, actor = pcall(function()
        gs = StaticFindObject("/Script/Engine.Default__GameplayStatics")
        return gs:BeginDeferredActorSpawnFromClass(c, class, transform, 1, nil)
      end)
      if not okB then f.err = "begin: " .. tostring(actor); return end
      if actor == nil then f.err = "begin: nil actor"; return end
      local okF, errF = pcall(function() gs:FinishSpawningActor(actor, transform) end)
      if not okF then f.err = "finish: " .. tostring(errF); return end
      local okV, valid = pcall(function() return actor:IsValid() end)
      if not okV or valid ~= true then f.err = "invalid actor"; return end
      f.spawned = true
      -- Controller: the Controller property first, then GetController().
      local candidates = {}
      local okP, ctrlP = pcall(function() return actor.Controller end)
      if okP and ctrlP ~= nil then candidates[#candidates + 1] = ctrlP end
      local okG, ctrlG = pcall(function() return actor:GetController() end)
      if okG and ctrlG ~= nil then candidates[#candidates + 1] = ctrlG end
      f.controller = #candidates > 0
      -- Start point: the spawner's Get() value, else the nearest OMDPathPoint.
      local point = WispSpawnerPoint(sp, kind)
      if point ~= nil then f.startPoint = "get"
      else
        point = WispNearestPoint(loc)
        if point ~= nil then f.startPoint = "near" end
      end
      if point ~= nil and #candidates > 0 then
        local okSS, errSS = WispSetStart(candidates, point)
        f.setStart = okSS
        if not okSS then f.err = "setstart: " .. tostring(errSS) end
      end
      -- Backstop: the actor ends after 20 s even if the clear command never runs.
      pcall(function() actor:SetLifeSpan(20) end)
      REFORGED_WISPS[#REFORGED_WISPS + 1] = { actor = actor, door = doorIndex, kind = kind, auto = auto }
    end)
    if not okAll then f.err = tostring(errAll) end
    if auto then
      WatchEmit("wisp", { op = "spawn", door = doorIndex, kind = kind, ok = f.spawned, auto = true, round = REFORGED.round })
      return f.spawned == true
    end
    print(string.format("[Reforged] wisp-probe door=%s kind=%s class=%s spawned=%s controller=%s startPoint=%s setStart=%s err=%s",
      tostring(doorIndex), tostring(kind), tostring(f.class), tostring(f.spawned), tostring(f.controller),
      tostring(f.startPoint), tostring(f.setStart), tostring(f.err)))
    WatchEmit("wisp", { op = "spawn", door = doorIndex, kind = kind, ok = f.spawned })
    return f.spawned == true
  end

  -- Destroys every valid probe wisp and empties the list.
  function WispClear()
    local n = 0
    for _, rec in ipairs(REFORGED_WISPS) do
      local okV, valid = pcall(function() return rec.actor:IsValid() end)
      if okV and valid == true then
        pcall(function() rec.actor:K2_DestroyActor() end)
        n = n + 1
      end
    end
    REFORGED_WISPS = {}
    print(string.format("[Reforged] wisp-clear n=%d", n))
    WatchEmit("wisp", { op = "clear", count = n }) -- not n: the row sequence uses n
  end

  -- Tick fields: the valid wisp count and the first valid wisp location {x, y}, rounded. Reads in pcall.
  function WispTickFields()
    local count, loc, locDone = 0, nil, false
    for _, rec in ipairs(REFORGED_WISPS) do
      local okV, valid = pcall(function() return rec.actor:IsValid() end)
      if okV and valid == true then
        count = count + 1
        if not locDone then
          locDone = true
          pcall(function()
            local p = rec.actor:K2_GetActorLocation()
            loc = { x = math.floor(p.X + 0.5), y = math.floor(p.Y + 0.5) }
          end)
        end
      end
    end
    return { count = count, loc = loc }
  end

  -- Reforged wisp preview. Each planned door gets one auto wisp at the build break. Kinds: flyer, heavy, normal.
  -- Auto wisps are cleared at combat start, map ready and preview off. Round state is in REFORGED: wispRound, wispKinds,
  -- wispMode, wispDelay, wispNextAt. A repeat runs only in wait mode.
  local WISP_HEAVY_WORDS = { "Heavy", "Armored", "Ogre", "Troll", "Basher", "King" }
  local WISP_AUTO_MAX = 3      -- live auto wisps per door
  local WISP_DELAY_DEFAULT = 3 -- seconds, when the coordinator's DelayBetweenWisps cannot be read

  -- True when the door's spawner is in the flyer-door table (PLACEMENT_STATIC) for its level.
  local function WispFlyerDoor(doorIndex)
    local sp = FindSpawnerByIndex(doorIndex)
    if not sp then return false end
    local level, name = SpawnerLevelAndName(sp)
    return level ~= nil and PLACEMENT_STATIC[level] ~= nil and PLACEMENT_STATIC[level][name] == "flyer-door"
  end

  -- Kind of one planned door. protos: set of proto names planned at the door this round. Flyer beats heavy.
  function ReforgedWispKind(doorIndex, protos)
    local flyer, heavy = false, false
    for name in pairs(protos or {}) do
      local s = tostring(name)
      if s:sub(1, 7) == "Hellbat" then flyer = true end
      if ReforgedIsBossName(s) then heavy = true end
      for _, w in ipairs(WISP_HEAVY_WORDS) do
        if s:find(w, 1, true) then heavy = true end
      end
    end
    if not flyer and WispFlyerDoor(doorIndex) then flyer = true end
    if flyer then return "flyer" end
    if heavy then return "heavy" end
    return "normal"
  end

  -- Break mode of the round's build break: the tracked break's mode, else the next-break setting. Round 1 waits.
  local function WispBreakMode(round)
    local brk = REFORGED_BREAK.brk
    if brk ~= nil and brk.mode ~= nil then return brk.mode end
    if round < 2 then return "wait" end
    return ReforgedBreakNext()
  end

  -- DelayBetweenWisps from the coordinator. A failed or bad read gives WISP_DELAY_DEFAULT.
  local function WispDelay()
    local okD, d = pcall(function() return coordinator().DelayBetweenWisps end)
    d = okD and tonumber(d) or nil
    if d == nil or d <= 0 then return WISP_DELAY_DEFAULT end
    return d
  end

  -- Live auto wisps at one door.
  local function WispLiveAuto(doorIndex)
    local n = 0
    for _, rec in ipairs(REFORGED_WISPS) do
      if rec.auto == true and rec.door == doorIndex then
        local okV, valid = pcall(function() return rec.actor:IsValid() end)
        if okV and valid == true then n = n + 1 end
      end
    end
    return n
  end

  -- One auto wisp at each planned door below the cap. kinds: door -> kind. Returns the count spawned.
  local function WispWave(doors, kinds)
    local n = 0
    for _, d in ipairs(doors) do
      if WispLiveAuto(d) < WISP_AUTO_MAX then
        local okS, ok = pcall(ReforgedWispSpawn, d, kinds[d] or "normal", true)
        if okS and ok == true then n = n + 1 end
      end
    end
    return n
  end

  -- Starts the round's wave. Kind, mode and delay are fixed for the break. Prints the one line of the round.
  local function WispStartRound(r)
    local doors = REFORGED.previewList or {}
    local protosBy = REFORGED.previewProtos or {}
    local kinds, doorText, kindText = {}, {}, {}
    for _, d in ipairs(doors) do
      local okK, kind = pcall(ReforgedWispKind, d, protosBy[d])
      kinds[d] = (okK and kind) or "normal"
      doorText[#doorText + 1] = tostring(d)
      kindText[#kindText + 1] = tostring(d) .. ":" .. kinds[d]
    end
    REFORGED.wispRound, REFORGED.wispKinds = r, kinds
    REFORGED.wispMode = WispBreakMode(r)
    REFORGED.wispDelay = WispDelay()
    REFORGED.wispNextAt = os.time() + REFORGED.wispDelay
    print(string.format("[Reforged] wisps round=%s doors=%s kinds=%s", tostring(r), JoinOrNone(doorText), JoinOrNone(kindText)))
    WispWave(doors, kinds)
  end

  -- Destroys every auto wisp and ends the round's wave. Probe wisps (auto false) stay. Emits a clear event when a wisp or a wave existed.
  function ReforgedWispClearAuto(why)
    local n, keep = 0, {}
    for _, rec in ipairs(REFORGED_WISPS) do
      if rec.auto == true then
        local okV, valid = pcall(function() return rec.actor:IsValid() end)
        if okV and valid == true then
          pcall(function() rec.actor:K2_DestroyActor() end)
          n = n + 1
        end
      else
        keep[#keep + 1] = rec
      end
    end
    REFORGED_WISPS = keep
    local hadWave = REFORGED.wispRound ~= nil
    REFORGED.wispRound, REFORGED.wispKinds, REFORGED.wispMode = nil, nil, nil
    if n > 0 or hadWave then WatchEmit("wisp", { op = "clear", count = n, why = tostring(why) }) end
    return n
  end

  -- One pass (game thread, after ReforgedBreakStep). Starts the round's wave when the build break is open, repeats it in
  -- wait mode, and clears the auto wisps when combat starts. Outside Reforged, or with preview off, it only clears.
  function ReforgedWispStep()
    local mode = QueueBlockMode()
    if mode ~= "reforged" or REFORGED_PREVIEW ~= true then
      if REFORGED.wispRound ~= nil then ReforgedWispClearAuto(mode ~= "reforged" and "mode" or "preview-off") end
      return
    end
    local phase = REFORGED.previewPhase
    local open = phase == "build-phase" or ReforgedTimedNow() == true
    -- An unknown phase (a failed read) changes nothing.
    if not open and phase ~= "released" then return end
    if not open then
      if REFORGED.wispRound ~= nil then ReforgedWispClearAuto("combat") end
      return
    end
    local r = REFORGED.round
    if REFORGED.wispRound ~= r and REFORGED.previewRound == r then
      WispStartRound(r)
    elseif REFORGED.wispRound == r and REFORGED.wispMode == "wait" and os.time() >= REFORGED.wispNextAt then
      REFORGED.wispNextAt = os.time() + REFORGED.wispDelay
      WispWave(REFORGED.previewList or {}, REFORGED.wispKinds or {})
    end
  end
end

-- Reads an actor location for walk and push. Returns {X,Y,Z} or nil.
function WalkReadLoc(pawn)
  local okL, l = pcall(function() return pawn:K2_GetActorLocation() end)
  if not okL or not l then return nil end
  local okV, x, y, z = pcall(function() return l.X, l.Y, l.Z end)
  if not okV or type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" then return nil end
  return { X = x, Y = y, Z = z }
end

-- Formats a location from WalkReadLoc as x,y,z in whole units.
function WalkFormatLoc(l)
  if not l then return "nil" end
  return string.format("%.0f,%.0f,%.0f", l.X, l.Y, l.Z)
end

local function DispatchCommand(line)
  WatchEmit("cmd", { line = tostring(line) })
  local op, arg1, arg2, arg3 = line:match("^%s*(%S+)%s*(%S*)%s*(%S*)%s*(%S*)%s*$")
  -- Lines with more than four words (probe) fail the pattern above; keep the verb.
  op = op or line:match("^%s*(%S+)")
  if DEV_OPS[op] and not TESTING then
    print("[Reforged] command rejected: " .. tostring(op) .. " is a developer command; send `testing on` first")
    return
  end
  if op == "testing" then
    if arg1 == "on" or arg1 == "off" then
      SetTesting(arg1 == "on")
      -- `testing on` is full testing. `testing off` also ends test mode.
      TESTING_LIGHT = false
      if arg1 == "off" then TEST_MODE = false end
    else print("[Reforged] testing=" .. tostring(TESTING)) end
  elseif op == "settings-reload" then
    local okS, errS = pcall(SettingsReload)
    if not okS then print("[Reforged] settings-reload failed: " .. tostring(errS)) end
  elseif op == "options-open" then
    OptionsCommandOpen(arg1 ~= "" and arg1 or nil)
  elseif op == "options-set" then
    OptionsCommandSet(arg1, arg2)
  elseif op == "menu-font" then
    MenuFontCommand(arg1)
  elseif op == "start-screen" then
    if arg1 == "on" then START_SCREEN = true
    elseif arg1 == "off" then START_SCREEN = false
    else print("[Reforged] start-screen rejected: use start-screen on|off"); return end
    print("[Reforged] start-screen=" .. (START_SCREEN and "on" or "off"))
  elseif op == "play-list" then
    GameNow(PlayUiList)
  elseif op == "watch" then
    if arg1 == "on" then WATCH_ON = true
    elseif arg1 == "off" then WATCH_ON = false
    else print("[Reforged] watch rejected: use watch on|off"); return end
    print("[Reforged] watch=" .. (WATCH_ON and "on" or "off") .. " file=" .. tostring(WatchFilePath()))
  elseif op == "watch-hits" then
    if arg1 ~= "on" and arg1 ~= "off" then print("[Reforged] watch-hits rejected: use watch-hits on|off"); return end
    print(WatchHitsSwitch(arg1 == "on"))
  elseif op == "hurt-player" then
    -- Test only: a known damage to the player pawn. Amount 1-50, default 5.
    local n = tonumber(arg1)
    if (arg1 ~= "" and not n) or (n and (n % 1 ~= 0 or n < 1 or n > 50)) then
      print("[Reforged] command rejected: hurt-player needs an integer from 1 to 50 (default 5)"); return
    end
    local amount = n or 5
    GameNow(function()
      local okH, errH = pcall(WatchHurtPlayer, amount)
      if not okH then print("[Reforged] hurt-player failed: " .. tostring(errH)) end
    end)
  elseif op == "rift-move" then
    -- Test only: the whole branch runs on the game thread. Forms: none or player, x y z, status. Anything else is rejected.
    GameNow(function()
      local words = {}
      for w in line:gmatch("%S+") do words[#words + 1] = w end
      local nx, ny, nz = tonumber(words[2]), tonumber(words[3]), tonumber(words[4])
      local target, status = nil, false
      if #words == 1 or (#words == 2 and words[2] == "player") then target = "player"
      elseif #words == 2 and words[2] == "status" then status = true
      elseif #words == 4 and nx and ny and nz then target = { X = nx, Y = ny, Z = nz }
      end
      if not status and not target then
        print("[Reforged] command rejected: rift-move needs player, status, or x y z"); return
      end
      local ok, err
      if status then ok, err = pcall(RiftStatus) else ok, err = pcall(RiftMove, target, "cmd") end
      if not ok then print("[Reforged] rift-move failed: " .. tostring(err)) end
    end)
  elseif op == "wisp-probe" then
    -- Test only: one wisp at one door. Door index is a whole number. Kind is normal (default), heavy or flyer.
    local door = tonumber(arg1)
    local kind = (arg2 ~= "" and arg2) or "normal"
    if not door or door ~= math.floor(door) or door < 0 then
      print("[Reforged] command rejected: wisp-probe needs a door index and an optional normal, heavy or flyer"); return
    end
    if kind ~= "normal" and kind ~= "heavy" and kind ~= "flyer" then
      print("[Reforged] command rejected: wisp-probe kind must be normal, heavy or flyer"); return
    end
    GameNow(function()
      local okW, errW = pcall(ReforgedWispSpawn, door, kind)
      if not okW then print("[Reforged] wisp-probe failed: " .. tostring(errW)) end
    end)
  elseif op == "wisp-clear" then
    GameNow(function()
      local okW, errW = pcall(WispClear)
      if not okW then print("[Reforged] wisp-clear failed: " .. tostring(errW)) end
    end)
  elseif op == "watch-track" then
    local ms = nil
    if arg1 == "off" then ms = 0
    else
      local n = tonumber(arg1)
      if n and n == math.floor(n) and n >= 500 and n <= 60000 then ms = math.floor(n) end
    end
    if not ms then print("[Reforged] watch-track rejected: use watch-track <500-60000>|off"); return end
    WATCH_TRACK_MS = ms
    print("[Reforged] watch-track=" .. tostring(ms))
  elseif op == "spawn" then
    local row = PROTO_BY_NAME[arg1]
    local count = ParseCount(arg2, "spawn")
    if not row then print("[Reforged] command rejected: unknown AI proto " .. tostring(arg1)); return end
    if count then RequestSpawn(row, count, "command") end
  elseif op == "random" then
    local count = ParseCount(arg1, "random")
    if count then RequestSpawn(PROTOS[math.random(#PROTOS)], count, "command-random") end
  elseif op == "mix" then
    local entries = {}
    local invalid
    for item in arg1:gmatch("[^,]+") do
      local name, count = item:match("^([%w_]+)=(%d+)$")
      local row = name and PROTO_BY_NAME[name]
      local amount = tonumber(count)
      if not row or not amount or amount < 1 or amount > 100 then invalid = item; break end
      entries[#entries + 1] = { row = row, count = amount }
    end
    if invalid or #entries < 2 then
      print("[Reforged] command rejected: use mix ProtoA=2,ProtoB=3 with at least two known protos")
      return
    end
    RequestSpawnBatch(entries, "command-mix")
  elseif op == "wave-amount" then
    local amount = ParseCount(arg1, "wave-amount")
    if amount then SetWaveAmount(amount) end
  elseif op == "wave-class" then
    SetWaveClass(arg1)
  elseif op == "inspect-protos" then
    GameNow(InspectProtoPointers)
  elseif op == "inspect-doors" then
    GameNow(InspectDoors)
  elseif op == "status" then
    GameNow(function()
      local c = coordinator()
      if not c then print("[Reforged] director status: no coordinator"); return end
      print("[Reforged] director status " .. population(c) .. " classes=" .. formatCounts(classCounts()))
    end)
  elseif op == "spawn-at" then
    local row = PROTO_BY_NAME[arg1]
    local count = ParseCount(arg2, "spawn-at")
    local doorIndex = tonumber(arg3)
    if not row then print("[Reforged] command rejected: unknown AI proto " .. tostring(arg1)); return end
    if not doorIndex or doorIndex % 1 ~= 0 then
      print("[Reforged] command rejected: spawn-at needs an integer doorIndex (run inspect-doors)")
      return
    end
    if count then ProbeSpawn("guid", row, count, doorIndex, 1) end
  elseif op == "probe" then
    -- probe guid|self|from <AIProto|-> <count> <doorIndex> [rank]
    local words = {}
    for w in line:gmatch("%S+") do words[#words + 1] = w end
    local mode, protoName = words[2], words[3]
    local count, doorIndex = tonumber(words[4]), tonumber(words[5])
    local rank = tonumber(words[6] or "1")
    local row = mode == "guid" and PROTO_BY_NAME[protoName or ""] or nil
    if mode ~= "guid" and mode ~= "self" and mode ~= "from" then
      print("[Reforged] command rejected: probe mode must be guid, self, or from")
      return
    end
    if mode == "guid" and not row then
      print("[Reforged] command rejected: probe guid needs a known AI proto")
      return
    end
    if not count or count < 1 or count > 10 or count % 1 ~= 0 then
      print("[Reforged] command rejected: probe count must be an integer from 1 to 10")
      return
    end
    if not doorIndex or doorIndex % 1 ~= 0 then
      print("[Reforged] command rejected: probe needs an integer doorIndex (run inspect-doors)")
      return
    end
    if not rank or rank < 1 or rank > 10 or rank % 1 ~= 0 then
      print("[Reforged] command rejected: probe rank must be an integer from 1 to 10")
      return
    end
    ProbeSpawn(mode, row, count, doorIndex, rank)
  elseif op == "door" then
    -- door <doorIndex> <AIProto> <count>: the door's native spawner spawns the proto
    local doorIndex = tonumber(arg1)
    local row = PROTO_BY_NAME[arg2]
    local count = ParseCount(arg3, "door")
    if not doorIndex or doorIndex % 1 ~= 0 then
      print("[Reforged] command rejected: door needs an integer doorIndex (run inspect-doors)")
      return
    end
    if not row then print("[Reforged] command rejected: unknown AI proto " .. tostring(arg2)); return end
    if count then DoorSpawn(doorIndex, row, count) end
  elseif op == "door-read" then
    local doorIndex = tonumber(arg1)
    if not doorIndex or doorIndex % 1 ~= 0 then print("[Reforged] command rejected: door-read needs an integer doorIndex"); return end
    DoorRead(doorIndex)
  elseif op == "wave" then
    local count = tonumber(arg1)
    local spacing = tonumber(arg2) or 10
    if not count or count < 1 or count > 20 or count % 1 ~= 0 then
      print("[Reforged] command rejected: wave needs an integer count from 1 to 20")
      return
    end
    if spacing < 1 or spacing > 60 or spacing % 1 ~= 0 then
      print("[Reforged] command rejected: wave spacing must be an integer from 1 to 60 seconds")
      return
    end
    RandomWave(count, spacing)
  elseif op == "wave-scaled" then
    local count, pct, spacing = tonumber(arg1), tonumber(arg2), tonumber(arg3) or 10
    if not count or count < 1 or count > 20 or count % 1 ~= 0 or not pct or pct < 0 or pct > 100 or spacing < 10 or spacing > 60 then
      print("[Reforged] command rejected: wave-scaled <count 1-20> <promotePct 0-100> [spacing 10-60]")
      return
    end
    ScaledWave(count, pct, spacing)
  elseif op == "distinct" then
    local count = tonumber(arg1)
    if not count or count < 1 or count > 8 or count % 1 ~= 0 then
      print("[Reforged] command rejected: distinct needs an integer count from 1 to 8")
      return
    end
    DistinctWave(count)
  elseif op == "sweep" then
    local door = tonumber(arg1)
    local delay = tonumber(arg2) or 15
    if not door or door < 1 or door > 3 or door % 1 ~= 0 then
      print("[Reforged] command rejected: sweep needs a door index 1 to 3")
      return
    end
    if delay < 1 or delay > 120 or delay % 1 ~= 0 then
      print("[Reforged] command rejected: sweep delay must be an integer from 1 to 120 seconds")
      return
    end
    SweepAll(door, delay)
  elseif op == "takeover" then
    if arg1 ~= "on" and arg1 ~= "off" then
      print("[Reforged] command rejected: takeover needs on or off")
      return
    end
    Takeover(arg1 == "on")
  elseif op == "wave-status" then
    GameNow(function()
      local alive = WaveAlive()
      print(string.format("[Reforged] wave-status active=%s label=%s tracked=%d alive=%d",
        tostring(waveTrack.active), waveTrack.label, (function() local n = 0; for _ in pairs(waveTrack.pawns) do n = n + 1 end; return n end)(), alive))
    end)
  elseif op == "breaks-read" then
    BreaksRead()
  elseif op == "breaks-off" then
    BreaksOff()
  elseif op == "start-endless-colosseum" then
    StartEndlessMission("Scenario_17_End")
  elseif op == "launch" then
    StartEndlessMission(arg1)
  elseif op == "banner" then
    -- Developer command: the text is the rest of the line, so it can hold spaces.
    HudBannerShow(line:match("^%s*banner%s+(.-)%s*$") or "", nil)
  elseif op == "difficulty" then
    DifficultyCommand(arg1)
  elseif op == "proto-check" then
    ProtoCheck(arg1)
  elseif op == "tally-reset" then
    GameNow(TallyReset)
  elseif op == "tally" then
    GameNow(TallyPrint)
  elseif op == "endless-add" then
    if QueueBlockMode() == "classic" then
      print("[Reforged] command rejected: endless-add changes enemy stats and is not allowed in Classic (#55)")
    else
      if arg1 == "stock" then endlessAddOverride = nil else endlessAddOverride = math.floor(tonumber(arg1) or 0) end
      print("[Reforged] endless-add override=" .. tostring(endlessAddOverride))
    end
  elseif op == "endless-promote" then
    if QueueBlockMode() == "classic" then
      print("[Reforged] command rejected: endless-promote changes enemy stats and is not allowed in Classic (#55)")
    else
      if arg1 == "stock" then endlessPromoteOverride = nil else endlessPromoteOverride = tonumber(arg1) or 0 end
      print("[Reforged] endless-promote override=" .. tostring(endlessPromoteOverride))
    end
  elseif op == "placement-open" then
    if arg1 == "on" or arg1 == "off" then
      PLACEMENT_REQUIRE_OPEN = arg1 == "on"
      print("[Reforged] placement-open=" .. arg1)
    else
      print("[Reforged] command rejected: placement-open needs on or off")
    end
  elseif op == "pawn-strip" then
    if arg1 == "on" or arg1 == "off" then
      PAWN_STRIP = arg1 == "on"
      print("[Reforged] pawn-strip=" .. arg1)
      if not PAWN_STRIP then GameNow(PawnStripRestore) end
    else
      print("[Reforged] command rejected: pawn-strip needs on or off")
    end
  elseif op == "pawn-collide" then
    if arg1 == "on" or arg1 == "off" then
      PAWN_COLLIDE_OFF = arg1 == "off"
      print("[Reforged] pawn-collide=" .. arg1)
      if not PAWN_COLLIDE_OFF then GameNow(PawnCollideRestore) end
    else
      print("[Reforged] command rejected: pawn-collide needs on or off")
    end
  elseif op == "hook-trace" then
    if arg1 == "on" or arg1 == "off" then
      HOOK_TRACE_ON = arg1 == "on"
      print("[Reforged] hook-trace=" .. arg1)
    else
      print("[Reforged] command rejected: hook-trace needs on or off")
    end
  elseif op == "hoard-gate" then
    if arg1 == "on" or arg1 == "off" then
      HOARD_GATE = arg1 == "on"
      print("[Reforged] hoard-gate=" .. arg1)
    else
      print("[Reforged] command rejected: hoard-gate needs on or off")
    end
  elseif op == "spawn-pace" then
    SpawnPaceCommand(arg1, arg2)
  elseif op == "preview" then
    ReforgedPreviewCommand(arg1)
  elseif op == "reforged-plan" then
    ReforgedPlanCommand(arg1, arg2)
  elseif op == "reforged-round" then
    ReforgedRoundCommand()
  elseif op == "reforged-round-next" then
    ReforgedRoundNextCommand(arg1)
  elseif op == "break-mode" then
    ReforgedBreakCommand(arg1, arg2)
  elseif op == "break-order" then
    ReforgedBreakOrderCommand(arg1, arg2)
  elseif op == "break-gate" then
    BreakGateCommand(arg1)
  elseif op == "modifier" then
    ReforgedModifierCommand(arg1, arg2)
  elseif op == "ai-perf" then
    AiPerf(line)
  elseif op == "pawn-flags" then
    PawnFlags(arg1 or "")
  elseif op == "perf" then
    if arg1 == "on" or arg1 == "lite" then
      PERF.on = true
      PERF.lite = arg1 == "lite"
      PERF.lastWave = nil; PERF.lastReal = nil; PERF.lastFrames = nil; PERF.lastPawns = {}
      print("[Reforged] perf " .. arg1)
    elseif arg1 == "off" then
      PERF.on = false
      PERF.lite = false
      print("[Reforged] perf off")
    else
      print("[Reforged] command rejected: perf needs on, off or lite")
    end
  elseif op == "custom-map-launch" then
    -- Not a developer command: no testing gate. Same launch as F8 in the Endless hub (#93 M2).
    -- Hub only (the same check as the F5 and F6 keys): the launch runs in the hub, on the game thread.
    local lib = REFORGED_CUSTOM and REFORGED_CUSTOM.lib
    if not lib or type(lib.Launch) ~= "function" then
      print("[Reforged] command rejected: custom-map-launch needs the custom-map module (" .. tostring(REFORGED_CUSTOM and REFORGED_CUSTOM.loadErr) .. ")")
      return
    end
    local name = arg1 ~= "" and arg1 or nil
    GameNow(function()
      if not EndlessHubOpen() then
        print("[Reforged] command rejected: custom-map-launch works only in the Endless hub")
        return
      end
      local okL, errL = pcall(lib.Launch, name)
      if not okL then print("[Reforged] custom-map launch err=" .. tostring(errL)) end
    end)
  elseif op == "cvar" then
    local name, value = line:match("^%s*cvar%s+(%S+)%s+(%S+)%s*$")
    if not name or not name:match("^[%w%._]+$") or not value or not value:match("^[%w%.%-]+$") then
      print("[Reforged] command rejected: cvar needs <name> <value>")
      return
    end
    GameNow(function() CvarRun(name, value) end)
  elseif op == "perf-class" then
    if not arg1 or not arg1:match("^[%w_]+$") then print("[Reforged] command rejected: perf-class needs a class name"); return end
    PERF_EXTRA[#PERF_EXTRA + 1] = arg1
    local name = arg1
    GameNow(function() print("[Reforged] perf-class added " .. name .. " count=" .. PerfCount(name)) end)
  elseif op == "stat-sample" then
    GameNow(StatSample)
  elseif op == "dm-read" then
    GameNow(DmRead)
  elseif op == "rift-rush" then
    GameNow(function()
      local fn = (arg1 == "off") and "DisableRiftRushCollisionSettings" or "EnableRiftRushCollisionSettings"
      local ok, bad = 0, 0
      for _, pawn in ipairs(FindAllOf("OMDAICharacter") or {}) do
        if pawn:IsValid() and not tostring(pawn:GetFName():ToString()):find("BP_Wisp_") then
          if pcall(function() pawn[fn](pawn) end) then ok = ok + 1 else bad = bad + 1 end
        end
      end
      print(string.format("[Reforged] rift-rush %s called=%d failed=%d", arg1 or "on", ok, bad))
    end)
  elseif op == "behavior" then
    -- Puts a stock tree in each live minion's AIDynamicBTree slot through OMDAIController.SetTempBehavior
    -- (native 0x140f57210). `default` gives each pawn
    -- its own tree back (GetAIBehavior). A developer command: in two live runs the game exited around the call.
    local trees = { NoMovement = true, MoveRandomly = true, Reverse_NodePath = true, SimpleNodePath = true, Default = true }
    local name = arg1 or ""
    if name ~= "default" and not trees[name] then
      print("[Reforged] behavior rejected: use default, NoMovement, MoveRandomly, Reverse_NodePath, SimpleNodePath or Default")
      return
    end
    GameNow(function()
      local tree = nil
      if name ~= "default" then
        local path = "/Game/Proto/Characters/Minions/_Base/AI/BTree_" .. name .. ".BTree_" .. name
        -- No LoadAsset: loading a tree's Blueprint tasks from Lua asserts on a non-game thread (2026-10-18).
        tree = StaticFindObject(path)
        if not tree or not tree:IsValid() then
          print("[Reforged] behavior " .. name .. " not in memory path=" .. path .. " (LoadAsset is not used: it crashed the game, #25)")
          return
        end
      end
      local ok, bad = 0, 0
      for _, e in ipairs(LiveNonWispAI()) do
        local done = pcall(function()
          local ctrl = e.actor.Controller
          if not ctrl or not ctrl:IsValid() then error("no controller") end
          ctrl:SetTempBehavior(tree or e.actor:GetAIBehavior())
        end)
        if done then ok = ok + 1 else bad = bad + 1 end
      end
      print(string.format("[Reforged] behavior %s called=%d failed=%d", name, ok, bad))
    end)
  elseif op == "bt-probe-load" then
    -- Gate for the tree load in bt-probe. Off by default: a LoadAsset of a tree crashed under UE4SS 3.0.1.
    if arg1 ~= "on" and arg1 ~= "off" then print("[Reforged] bt-probe-load rejected: use bt-probe-load on|off"); return end
    BT_PROBE_ALLOW_LOAD = arg1 == "on"
    print("[Reforged] bt-probe-load=" .. (BT_PROBE_ALLOW_LOAD and "on" or "off"))
  elseif op == "bt-probe" then
    -- Diagnostic: one pawn, step logs around RunBehaviorTree or SetTempBehavior.
    local probeTrees = { NoMovement = true, MoveRandomly = true, Reverse_NodePath = true, SimpleNodePath = true, Default = true }
    local probeName, probeMethod = arg1 or "", arg2 or ""
    if not probeTrees[probeName] or (probeMethod ~= "run" and probeMethod ~= "temp" and probeMethod ~= "read") then
      print("[Reforged] bt-probe rejected: use bt-probe <NoMovement|MoveRandomly|Reverse_NodePath|SimpleNodePath|Default> <run|temp|read>")
      return
    end
    local function ProbeValid(o)
      local ok, v = pcall(function() return o ~= nil and o:IsValid() end)
      return ok and v == true
    end
    -- Object id for logs and the watch stream: the text after the last "." of GetFullName.
    local function ProbeId(full)
      return tostring(full):match("%.([^%.%s]+)$") or tostring(full)
    end
    GameNow(function()
      local path = "/Game/Proto/Characters/Minions/_Base/AI/BTree_" .. probeName .. ".BTree_" .. probeName
      print("[Reforged] bt-probe step tree-find path=" .. path)
      local function FindTree()
        local found = nil
        pcall(function() found = StaticFindObject(path) end)
        return found
      end
      local tree = FindTree()
      local treeOk = ProbeValid(tree)
      if not treeOk and BT_PROBE_ALLOW_LOAD then
        -- Gated by bt-probe-load on. Runs here, on the game thread.
        local okL, errL = pcall(function() return LoadAsset(path) end)
        print(string.format("[Reforged] bt-probe load %s ok=%s err=%s", path, tostring(okL), tostring(errL)))
        tree = FindTree()
        treeOk = ProbeValid(tree)
      end
      local _, treeName = pcall(function() return tree:GetFullName() end)
      print(string.format("[Reforged] bt-probe tree ok=%s name=%s", tostring(treeOk), tostring(treeName)))
      if not treeOk then
        local hint = BT_PROBE_ALLOW_LOAD and "load failed" or "bt-probe-load on allows a load"
        print("[Reforged] bt-probe " .. probeName .. " not in memory path=" .. path .. " (" .. hint .. "; #25)")
        return
      end

      -- Pick from the controllers. A controller counts when its pawn is valid, not dead (bIsDead false) and not a Wisp.
      print("[Reforged] bt-probe step pick")
      local okCtrls, ctrls = pcall(FindAllOf, "OMDAIController")
      if not okCtrls or not ctrls then ctrls = {} end
      local ctrl, pawn, ctrlFull, pawnFull = nil, nil, nil, nil
      for _, c in ipairs(ctrls) do
        if ProbeValid(c) then
          local okP, p = pcall(function() return c:K2_GetPawn() end)
          if okP and ProbeValid(p) then
            local okPF, pf = pcall(function() return p:GetFullName() end)
            local okD, dead = pcall(function() return p.bIsDead end)
            if okPF and pf and not tostring(pf):find("BP_Wisp_") and okD and dead == false then
              local _, cf = pcall(function() return c:GetFullName() end)
              ctrl, ctrlFull, pawn, pawnFull = c, cf, p, pf
              break
            end
          end
        end
      end
      if not ctrl or not pawn then print("[Reforged] bt-probe no live AI controller"); return end
      print(string.format("[Reforged] bt-probe pick controller=%s pawn=%s", ProbeId(ctrlFull), ProbeId(pawnFull)))

      -- Extra log lines only: the picked controller does not depend on these reads.
      local okProp, propCtrl = pcall(function() return pawn.Controller end)
      local propValid = okProp and ProbeValid(propCtrl)
      print(string.format("[Reforged] bt-probe controller-prop ok=%s valid=%s type=%s", tostring(okProp), tostring(propValid), type(propCtrl)))
      local okGc, gcCtrl = pcall(function() return pawn:GetController() end)
      local gcValid = okGc and ProbeValid(gcCtrl)
      local _, gcName = pcall(function() return gcCtrl:GetFullName() end)
      print(string.format("[Reforged] bt-probe GetController ok=%s valid=%s name=%s", tostring(okGc), tostring(gcValid), tostring(gcName)))

      print("[Reforged] bt-probe step GetAIBehavior")
      local okBeh, behavior = pcall(function() return pawn:GetAIBehavior() end)
      local behValue = tostring(behavior)
      if okBeh then
        local okName, behName = pcall(function() return behavior:GetFullName() end)
        behValue = tostring(behName)
      end
      print(string.format("[Reforged] bt-probe GetAIBehavior ok=%s value=%s", tostring(okBeh), behValue))

      if probeMethod == "run" or probeMethod == "temp" then
        print("[Reforged] bt-probe step call " .. probeMethod)
        local okCall, ret = pcall(function()
          if probeMethod == "run" then return ctrl:RunBehaviorTree(tree) end
          return ctrl:SetTempBehavior(tree)
        end)
        print(string.format("[Reforged] bt-probe call %s ok=%s result=%s", probeMethod, tostring(okCall), tostring(ret)))
        if probeMethod == "run" then
          local okBrain, brain = pcall(function() return ctrl.BrainComponent end)
          local _, brainName = pcall(function() return brain:GetFullName() end)
          print(string.format("[Reforged] bt-probe brain ok=%s name=%s", tostring(okBrain), tostring(brainName)))
        end
        -- Host hint: the id for `omdwatch.py track <id>` (same id as the watch stream).
        print("[Reforged] bt-probe watch pawn=" .. ProbeId(pawnFull))
      end

      print("[Reforged] bt-probe step loc-base")
      local okBase, base = pcall(function() return pawn:K2_GetActorLocation() end)
      print(string.format("[Reforged] bt-probe baseline ok=%s loc=%s", tostring(okBase), okBase and Vec(base) or tostring(base)))
      local last = okBase and base or nil

      local count, stopped = 0, false
      GameLoop(1000, function()
        if stopped or count >= 6 then return true end
        count = count + 1
        local n = count
        do
          local function gtBody()
            local okLoc, loc = pcall(function()
              if not ProbeValid(pawn) then error("pawn gone") end
              return pawn:K2_GetActorLocation()
            end)
            if not okLoc or not loc then
              print(string.format("[Reforged] bt-probe sample %d/6 pawn gone", n))
              stopped = true
              return
            end
            local moved = 0
            if last then
              local okD, d = pcall(function()
                local dx, dy, dz = loc.X - last.X, loc.Y - last.Y, loc.Z - last.Z
                return math.sqrt(dx * dx + dy * dy + dz * dz)
              end)
              if okD then moved = d end
            end
            last = loc
            print(string.format("[Reforged] bt-probe sample %d/6 loc=%s moved=%.0f", n, Vec(loc), moved))
          end
          gtBody()
        end
        return false
      end)
    end)
  -- Diagnostic: a coordinator spawn that the game counts (SpawnEntityForEntity -> 0x140fbb550).
  elseif op == "anchor-boot" then
    local door = math.tointeger(tonumber(arg1 or ""))
    if not door or door < 0 then
      print("[Reforged] anchor-boot rejected: use anchor-boot <doorIndex>")
      return
    end
    SafeRun("anchor-boot", AnchorBoot, door)
  elseif op == "anchor-hold" then
    GameNow(function() SafeRun("anchor-hold", AnchorHold) end)
  elseif op == "anchor-release" then
    GameNow(function() SafeRun("anchor-release", AnchorRelease) end)
  elseif op == "anchor-status" then
    GameNow(function() SafeRun("anchor-status", AnchorStatus) end)
  elseif op == "queue-block" then
    GameNow(function() SafeRun("queue-block", QueueBlockCommand, arg1) end)
  elseif op == "tick-hold" then
    if arg1 == "auto" then
      GameNow(function() SafeRun("tick-hold", TickHoldAutoCommand, arg2) end)
    elseif arg1 == "on" or arg1 == "off" then
      GameNow(function() SafeRun("tick-hold", TickHold, arg1 == "on") end)
    else
      GameNow(function() SafeRun("tick-hold", TickHoldPrint); SafeRun("tick-hold", TickHoldAutoPrint) end)
    end
  elseif op == "anchor-health" then
    GameNow(function() SafeRun("anchor-health", AnchorHealth) end)
  elseif op == "anchor-hold-mode" then
    if arg1 ~= "tree" and arg1 ~= "brain" and arg1 ~= "dilation" then
      print("[Reforged] anchor-hold-mode rejected: use anchor-hold-mode tree|brain|dilation")
      return
    end
    ANCHOR_HOLD_MODE = arg1
    print("[Reforged] anchor-hold-mode=" .. arg1)
  elseif op == "anchor-auto" then
    if arg1 ~= "on" and arg1 ~= "off" then
      print("[Reforged] anchor-auto rejected: use anchor-auto on|off")
      return
    end
    ANCHOR_AUTO = arg1 == "on"
    if ANCHOR_AUTO then AnchorAutoStart() else ANCHOR_AUTO_GEN = ANCHOR_AUTO_GEN + 1 end
    print("[Reforged] anchor-auto=" .. arg1)
  elseif op == "anchor-native" then
    if arg1 ~= "on" and arg1 ~= "off" then
      print("[Reforged] anchor-native rejected: use anchor-native on|off")
      return
    end
    ANCHOR_FROM_NATIVE = arg1 == "on"
    print("[Reforged] anchor-native=" .. arg1)
  elseif op == "anchor-min-dist" then
    local units = math.tointeger(tonumber(arg1 or ""))
    if not units or units < 200 or units > 5000 then
      print("[Reforged] anchor-min-dist rejected: use anchor-min-dist 200-5000")
      return
    end
    ANCHOR_MIN_DOOR_DIST = units
    print("[Reforged] anchor-min-dist=" .. units)
  elseif op == "cspawn" then
    local door = math.tointeger(tonumber(arg1 or ""))
    local count = math.tointeger(tonumber(arg3 or ""))
    local row = PROTO_BY_NAME[arg2 or ""]
    if not door or door < 0 or not row or not count or count < 1 or count > 10 then
      print("[Reforged] cspawn rejected: use cspawn <door> <AIProto> <1-10>")
      return
    end
    GameNow(function() SafeRun("cspawn", CountedSpawn, door, arg2, count) end)
  elseif op == "coord-spawn-pos" then
    local count = tonumber(arg1)
    local variant = arg2 == "" and "full" or arg2
    local VARIANTS = { full = true, noout = true, nilsrc = true, ["noout-nilsrc"] = true, table = true, ["table-noout"] = true, lib = true }
    local USAGE = "[Reforged] coord-spawn-pos rejected: use coord-spawn-pos <1-3> [full|noout|nilsrc|noout-nilsrc|table|table-noout|lib] [AIProto]"
    if not count or count ~= math.floor(count) or count < 1 or count > 3 or not VARIANTS[variant] then
      print(USAGE)
      return
    end
    -- Optional AI proto name. Only the table variant uses it: the proto table then comes from PROTO_BY_NAME.
    local protoRow = nil
    if arg3 ~= "" then
      protoRow = PROTO_BY_NAME[arg3]
      if not protoRow then print(USAGE); return end
      if variant ~= "table" then
        print("[Reforged] coord-spawn-pos rejected: a proto argument needs the table variant")
        return
      end
    end
    local function ProbeValid(o)
      local ok, v = pcall(function() return o ~= nil and o:IsValid() end)
      return ok and v == true
    end
    local function Read(f)
      local ok, v = pcall(f)
      if ok then return tostring(v) end
      return "error " .. tostring(v)
    end
    local function ErrText(e)
      if type(e) == "function" then
        local ok, r = pcall(e)
        if ok then return "fn->" .. tostring(r) end
        return "fn(err " .. tostring(r) .. ")"
      end
      if type(e) == "userdata" or type(e) == "table" then
        local ok, s = pcall(function() return e:ToString() end)
        if ok and s ~= nil then return tostring(s) end
        ok, s = pcall(tostring, e)
        if ok then return tostring(s) end
        return type(e)
      end
      return tostring(e)
    end
    GameNow(function()
      print("[Reforged] coord-spawn-pos step coordinator")
      local okC, c = pcall(coordinator)
      if not okC or not c then print("[Reforged] coord-spawn-pos no coordinator"); return end
      print("[Reforged] coord-spawn-pos coordinator ok=true")

      print("[Reforged] coord-spawn-pos step before")
      local alive0 = Read(function() return c:GetNumPawnsAlive() end)
      local live0 = Read(function() return #LiveNonWispAI() end)
      print(string.format("[Reforged] coord-spawn-pos before alive=%s live=%s", alive0, live0))

      print("[Reforged] coord-spawn-pos step pawn-find")
      local okList, list = pcall(LiveNonWispAI)
      if not okList then print("[Reforged] coord-spawn-pos pawns error=" .. tostring(list)); return end
      local src, srcFull = nil, nil
      for _, entry in ipairs(list) do
        if ProbeValid(entry.actor) then src, srcFull = entry.actor, entry.full; break end
      end
      if not src then print("[Reforged] coord-spawn-pos no live pawn (spawn one with door first)"); return end
      print("[Reforged] coord-spawn-pos pawn=" .. ShortName(srcFull))
      local protoName = Read(function() return src:GetProtoName():ToString() end)
      print("[Reforged] coord-spawn-pos proto-name=" .. protoName)

      print("[Reforged] coord-spawn-pos step proto")
      local okP, proto = pcall(function() return src.protodata end)
      local protoOk = okP and proto ~= nil
      local guidA = Read(function() return proto.Guid.A end)
      print(string.format("[Reforged] coord-spawn-pos proto ok=%s guidA=%s", tostring(protoOk), guidA))
      if not protoOk then print("[Reforged] coord-spawn-pos stop: proto unreadable, no call"); return end

      if protoRow then
        local g = protoRow.guid
        proto = { Guid = { A = g.A, B = g.B, C = g.C, D = g.D } }
        print(string.format("[Reforged] coord-spawn-pos proto-override %s guid A=%s B=%s C=%s D=%s", protoRow.name, g.A, g.B, g.C, g.D))
      elseif variant == "table" or variant == "table-noout" then
        local okGA, ga = pcall(function() return src.protodata.Guid.A end)
        local okGB, gb = pcall(function() return src.protodata.Guid.B end)
        local okGC, gc = pcall(function() return src.protodata.Guid.C end)
        local okGD, gd = pcall(function() return src.protodata.Guid.D end)
        local function GV(ok, v) if ok then return tostring(v) end return "error" end
        print(string.format("[Reforged] coord-spawn-pos guid A=%s B=%s C=%s D=%s", GV(okGA, ga), GV(okGB, gb), GV(okGC, gc), GV(okGD, gd)))
        if not (okGA and okGB and okGC and okGD) then print("[Reforged] coord-spawn-pos stop: guid unreadable, no call"); return end
        proto = { Guid = { A = ga, B = gb, C = gc, D = gd } }
      end

      if variant == "lib" then
        local okLib, lib = pcall(ProtoLibrary)
        local okFind, ptr = false, nil
        if okLib and lib then
          okFind, ptr = pcall(function() return lib:FindAICharacterSoftProtoPtrByName(FName(protoName, EFindName.FNAME_Add)) end)
        end
        print(string.format("[Reforged] coord-spawn-pos lib find ok=%s result=%s type=%s", tostring(okFind), okFind and tostring(ptr) or ErrText(ptr), type(ptr)))
        if not (okLib and lib and okFind) then print("[Reforged] coord-spawn-pos stop: lib find failed, no call"); return end
        proto = ptr
      end

      print("[Reforged] coord-spawn-pos step pos")
      local okBase, base = pcall(function() return src:K2_GetActorLocation() end)
      if not okBase or not base then print("[Reforged] coord-spawn-pos stop: no location, no call"); return end
      local pos = { X = base.X + 150, Y = base.Y, Z = base.Z }
      local rot = { Pitch = 0, Yaw = 0, Roll = 0 }
      print("[Reforged] coord-spawn-pos pos=" .. Vec(pos))

      print("[Reforged] coord-spawn-pos step call variant=" .. variant)
      local out = {}
      local okCall, ret
      if variant == "full" then
        okCall, ret = pcall(function() return c:SpawnEntityForEntity(src, pos, rot, proto, count, false, out) end)
      elseif variant == "noout" then
        okCall, ret = pcall(function() return c:SpawnEntityForEntity(src, pos, rot, proto, count, false) end)
      elseif variant == "nilsrc" then
        okCall, ret = pcall(function() return c:SpawnEntityForEntity(nil, pos, rot, proto, count, false, out) end)
      elseif variant == "table" or variant == "lib" then
        okCall, ret = pcall(function() return c:SpawnEntityForEntity(src, pos, rot, proto, count, false, out) end)
      elseif variant == "table-noout" then
        okCall, ret = pcall(function() return c:SpawnEntityForEntity(src, pos, rot, proto, count, false) end)
      else
        okCall, ret = pcall(function() return c:SpawnEntityForEntity(nil, pos, rot, proto, count, false) end)
      end
      print(string.format("[Reforged] coord-spawn-pos call ok=%s result=%s outType=%s", tostring(okCall), okCall and tostring(ret) or ErrText(ret), type(out)))
      if okCall then
        local okN, n = pcall(function() return out:GetArrayNum() end)
        if not okN then okN, n = pcall(function() return #out end) end
        print(string.format("[Reforged] coord-spawn-pos out n=%s", okN and tostring(n) or ("error " .. ErrText(n))))
      end

      print("[Reforged] coord-spawn-pos step samples")
      local n = 0
      GameLoop(1000, function()
        if n >= 8 then return true end
        n = n + 1
        local i = n
        local cc = coordinator()
        local alive = Read(function()
          if not cc then error("no coordinator") end
          return cc:GetNumPawnsAlive()
        end)
        local live = Read(function() return #LiveNonWispAI() end)
        print(string.format("[Reforged] coord-spawn-pos sample %d/8 alive=%s live=%s", i, alive, live))
        return false
      end)
    end)
  -- Diagnostic: the coordinator queue route (OnslaughtStartGroup + OnslaughtSpawnEntities) with a table proto.
  elseif op == "coord-queue" then
    local row = PROTO_BY_NAME[arg1]
    local count = tonumber(arg2)
    if not row or not count or count ~= math.floor(count) or count < 1 or count > 5 then
      print("[Reforged] coord-queue rejected: use coord-queue <AIProto> <1-5>")
      return
    end
    local function Read(f)
      local ok, v = pcall(f)
      if ok then return tostring(v) end
      return "error " .. tostring(v)
    end
    local function ErrText(e)
      if type(e) == "function" then
        local ok, r = pcall(e)
        if ok then return "fn->" .. tostring(r) end
        return "fn(err " .. tostring(r) .. ")"
      end
      if type(e) == "userdata" or type(e) == "table" then
        local ok, s = pcall(function() return e:ToString() end)
        if ok and s ~= nil then return tostring(s) end
        ok, s = pcall(tostring, e)
        if ok then return tostring(s) end
        return type(e)
      end
      return tostring(e)
    end
    GameNow(function()
      local okC, c = pcall(coordinator)
      if not okC or not c then print("[Reforged] coord-queue no coordinator"); return end

      local alive0 = Read(function() return c:GetNumPawnsAlive() end)
      local waiting0 = Read(function() return c:GetNumPawnsWaitingForSpawn() end)
      local approved0 = Read(function() return c:GetNumPawnsApprovedForSpawn() end)
      print(string.format("[Reforged] coord-queue before alive=%s waiting=%s approved=%s", alive0, waiting0, approved0))

      local okG, errG = pcall(function() c:OnslaughtStartGroup(0.0) end)
      print(string.format("[Reforged] coord-queue start-group ok=%s err=%s", tostring(okG), okG and "nil" or ErrText(errG)))

      local guid = row.guid
      local okS, errS = pcall(function()
        c:OnslaughtSpawnEntities({ Guid = { A = guid.A, B = guid.B, C = guid.C, D = guid.D } }, count, false, 0, 0.0, 5)
      end)
      print(string.format("[Reforged] coord-queue spawn-entities ok=%s err=%s", tostring(okS), okS and "nil" or ErrText(errS)))

      local n = 0
      GameLoop(1000, function()
        if n >= 12 then return true end
        n = n + 1
        local i = n
        local okL, line = pcall(function()
          local cc = coordinator()
          if not cc then error("no coordinator", 0) end
          return string.format("alive=%s waiting=%s approved=%s",
            Read(function() return cc:GetNumPawnsAlive() end),
            Read(function() return cc:GetNumPawnsWaitingForSpawn() end),
            Read(function() return cc:GetNumPawnsApprovedForSpawn() end))
        end)
        if okL then
          print(string.format("[Reforged] coord-queue sample %d/12 %s", i, line))
        else
          print(string.format("[Reforged] coord-queue sample %d/12 error=%s", i, ErrText(line)))
        end
        return false
      end)
    end)
  -- Diagnostic: which proto form UE4SS passes intact (IsSoftProtoPtrValid).
  elseif op == "proto-pass" then
    local name = arg1
    local row = PROTO_BY_NAME[name]
    if not row then print("[Reforged] proto-pass rejected: unknown AI proto " .. tostring(name)); return end
    local function ProbeValid(o)
      local ok, v = pcall(function() return o ~= nil and o:IsValid() end)
      return ok and v == true
    end
    local function ErrText(e)
      if type(e) == "function" then
        local ok, r = pcall(e)
        if ok then return "fn->" .. tostring(r) end
        return "fn(err " .. tostring(r) .. ")"
      end
      if type(e) == "userdata" or type(e) == "table" then
        local ok, s = pcall(function() return e:ToString() end)
        if ok and s ~= nil then return tostring(s) end
        ok, s = pcall(tostring, e)
        if ok then return tostring(s) end
        return type(e)
      end
      return tostring(e)
    end
    GameNow(function()
      print(string.format("[Reforged] proto-pass %s step gameplay-statics", name))
      local okS, gs = pcall(StaticFindObject, "/Script/OMD.Default__OMDGameplayStatics")
      local gsFound = okS and gs ~= nil
      local gsValid = gsFound and ProbeValid(gs)
      print(string.format("[Reforged] proto-pass %s gameplay-statics found=%s valid=%s", name, tostring(gsFound), tostring(gsValid)))
      if not gsValid then return end

      local function Check(form, value)
        local okV, v = pcall(function() return gs:IsSoftProtoPtrValid(value) end)
        print(string.format("[Reforged] proto-pass %s %s valid ok=%s result=%s", name, form, tostring(okV), okV and tostring(v) or ErrText(v)))
      end

      print(string.format("[Reforged] proto-pass %s step table", name))
      local okT, tbl = pcall(function() return { Guid = { A = row.guid.A, B = row.guid.B, C = row.guid.C, D = row.guid.D } } end)
      if okT then Check("table", tbl) else print(string.format("[Reforged] proto-pass %s table build error=%s", name, ErrText(tbl))) end

      print(string.format("[Reforged] proto-pass %s step zero", name))
      Check("zero", { Guid = { A = 0, B = 0, C = 0, D = 0 } })

      print(string.format("[Reforged] proto-pass %s step lib", name))
      local okLib, lib = pcall(ProtoLibrary)
      if okLib and lib then
        local okF, ptr = pcall(function() return lib:FindAICharacterSoftProtoPtrByName(FName(name, EFindName.FNAME_Add)) end)
        print(string.format("[Reforged] proto-pass %s lib find ok=%s result=%s type=%s", name, tostring(okF), okF and tostring(ptr) or ErrText(ptr), type(ptr)))
        if okF then Check("lib", ptr) end
      else
        print(string.format("[Reforged] proto-pass %s lib library not found", name))
      end

      print(string.format("[Reforged] proto-pass %s step pawn", name))
      local okList, list = pcall(LiveNonWispAI)
      local pawn = nil
      if okList then
        for _, entry in ipairs(list) do
          if ProbeValid(entry.actor) then
            local okN, pn = pcall(function() return entry.actor:GetProtoName():ToString() end)
            if okN and pn == name then pawn = entry.actor; break end
          end
        end
      end
      if not pawn then
        print(string.format("[Reforged] proto-pass %s pawn skipped: no live pawn of %s", name, name))
      else
        local okP, pd = pcall(function() return pawn.protodata end)
        if okP and pd ~= nil then Check("pawn", pd)
        else print(string.format("[Reforged] proto-pass %s pawn protodata unreadable", name)) end
      end
    end)
  elseif op == "class-props" then
    GameNow(function()
      local o = FindFirstOf(arg1 or "")
      if not o or not o:IsValid() then print("[Reforged] class-props: no instance of " .. tostring(arg1)); return end
      local names = {}
      local c = o:GetClass()
      while c and c:IsValid() do
        local cn = c:GetFName():ToString()
        if cn == "Object" then break end
        c:ForEachProperty(function(pr) names[#names + 1] = cn .. "." .. pr:GetFName():ToString() end)
        pcall(function() c:ForEachFunction(function(fn) names[#names + 1] = cn .. ":" .. fn:GetFName():ToString() end) end)
        c = c:GetSuperStruct()
      end
      print("[Reforged] class-props " .. arg1 .. " n=" .. #names .. " " .. table.concat(names, " "))
    end)
  elseif op == "dm-set" then
    -- Classic may restore a stock value (`stock`) but not set one.
    if QueueBlockMode() == "classic" and arg2 ~= "stock" then
      print("[Reforged] command rejected: dm-set changes enemy stats and is not allowed in Classic (#55)")
    else
      GameNow(function() DmSet(arg1, arg2) end)
    end
  elseif op == "dm-list" then
    -- dm-list has up to five words, so the four-capture match above drops them. Split the raw line again.
    local w = {}
    for word in line:gmatch("%S+") do w[#w + 1] = word end
    GameNow(function()
      local okL, errL = pcall(DmListRun, w[2], w[3], w[4], w[5])
      if not okL then print("[Reforged] dm-list failed: " .. tostring(errL)) end
    end)
  elseif op == "curve" then
    -- curve has up to four words; split the raw line like dm-list.
    local w = {}
    for word in line:gmatch("%S+") do w[#w + 1] = word end
    GameNow(function()
      local okC, errC = pcall(CurveCommand, w[2], w[3], w[4])
      if not okC then print("[Reforged] curve failed: " .. tostring(errC)) end
    end)
  elseif op == "dmg-read" then
    GameNow(DmgRead)
  elseif op == "dmg-probe" then
    if arg1 == "on" then GameNow(DmgProbeOn)
    else print("[Reforged] dmg-probe on=" .. tostring(dmgCalls.on) .. " calls=" .. tostring(dmgCalls.n)) end
  elseif op == "player-path" then
    GameNow(function()
      local okP, errP = pcall(PlayerPathCommand, line)
      if not okP then print("[Reforged] player-path failed: " .. tostring(errP)) end
    end)
  elseif op == "feign" then
    GameNow(function() FeignSet(arg1 ~= "off") end)
  elseif op == "wave-amount-at" then
    local secs, amount = tonumber(arg1), tonumber(arg2)
    if not secs or not amount then print("[Reforged] command rejected: wave-amount-at <seconds> <amount>"); return end
    pendingWaveAmount = { secs = secs, amount = amount }
    print(string.format("[Reforged] wave-amount-at armed: %d s after the next round start, amount %d", secs, amount))
  elseif op == "profile-run" then
    if RunProfile then RunProfile(arg1) else print("[Reforged] profile unavailable: command path not resolved") end
  elseif op == "profile-stop" then
    if ProfileStop then ProfileStop() end
  elseif op == "wave-file" then
    if RunWaveFile then RunWaveFile(arg1) else print("[Reforged] wave-file unavailable: command path not resolved") end
  elseif op == "coordinator-class" then
    GameNow(CoordinatorClass)
  elseif op == "rift-target" then
    if arg1 == "off" then RIFT_TARGET = nil
    else
      local v = tonumber(arg1)
      if not v or v < 1 or v > 100000 or v % 1 ~= 0 then print("[Reforged] command rejected: rift-target needs off or an integer from 1 to 100000"); return end
      RIFT_TARGET = v
    end
    print("[Reforged] rift-target now " .. tostring(RIFT_TARGET))
    GameNow(function() local c = coordinator(); if c and RIFT_TARGET ~= nil then pcall(function() c.RiftPoints = RIFT_TARGET end) end end)
  elseif op == "route-prefer" then
    if arg1 ~= "first" and arg1 ~= "second" and arg1 ~= "stock" then print("[Reforged] command rejected: route-prefer needs first, second or stock"); return end
    GameNow(function() RoutePrefer(arg1) end)
  elseif op == "goblin-status" then
    GameNow(function()
      local _, coin = GoblinPlayerCoin()
      local parts = {}
      for _, g in ipairs(goblins) do parts[#parts + 1] = string.format("%s health=%s", ShortName(g.full), tostring(g.health)) end
      print(string.format("[Reforged] goblin-status goblins=%d coinsPerHit=%d playerCoin=%s %s", #goblins, GOBLIN_COINS, tostring(coin), table.concat(parts, "; ")))
    end)
  elseif op == "goblin-coins" then
    local n = tonumber(arg1)
    if not n or n % 1 ~= 0 or n < 1 or n > 50 then print("[Reforged] command rejected: goblin-coins needs an integer from 1 to 50"); return end
    GOBLIN_COINS = n; print("[Reforged] goblin-coins now " .. n)
  elseif op == "goblin-hit" then
    -- Test only: lower a goblin's Health by `arg1` (default 1), as a hit would. `arg2` is the goblin's number (default: the newest).
    local dmg = tonumber(arg1) or 1
    GameNow(function()
      local g = goblins[tonumber(arg2) or #goblins]
      if not g then print("[Reforged] goblin-hit: no such goblin registered"); return end
      local ok, err = pcall(function() g.actor.Health = g.actor.Health - dmg end)
      print(string.format("[Reforged] goblin-hit simulated -%s ok=%s%s", tostring(dmg), tostring(ok), ok and "" or (" err=" .. tostring(err))))
    end)
  elseif op == "moneybags-kill" then
    -- Test only: apply 100000 damage to up to `arg1` kept door Moneybags (default 1), by the same two routes as hurt-player.
    -- The record stays and no coins are paid here. ReforgedMoneybagsStep pays the death.
    local n = tonumber(arg1) or 1
    GameNow(function()
      if next(REFORGED_RULES.mb) == nil then print("[Reforged] moneybags-kill: no kept Moneybags"); return end
      local done = 0
      for full, rec in pairs(REFORGED_RULES.mb) do
        if done >= n then break end
        done = done + 1
        local route = "none"
        local okE = pcall(function()
          local gs = StaticFindObject("/Script/Engine.Default__GameplayStatics")
          gs:ApplyDamage(rec.actor, 100000, nil, nil, nil)
        end)
        if okE then route = "engine"
        else
          local okO = pcall(function()
            local gs = StaticFindObject("/Script/OMD.Default__OMDGameplayStatics")
            gs:ApplyDamage(rec.actor, 100000, nil, nil, nil)
          end)
          if okO then route = "omd" end
        end
        print(string.format("[Reforged] moneybags-kill %s route=%s", ShortName(full), route))
      end
    end)
  elseif op == "coin-give" then
    -- Test: call an OMDPlayerController coin method and read the coin count now and 0.7 s later. A working method also becomes the goblin's.
    local method, n = arg1, tonumber(arg2) or 3
    if method ~= "GiveCoin" and method ~= "AddCoin" and method ~= "Server_GiveCoin" then print("[Reforged] command rejected: coin-give needs GiveCoin, AddCoin or Server_GiveCoin"); return end
    GameNow(function()
      local pc, before = GoblinPlayerCoin()
      if not pc then print("[Reforged] coin-give: no player controller"); return end
      local ok, err = pcall(function() pc[method](pc, n) end)
      local _, now = GoblinPlayerCoin()
      print(string.format("[Reforged] coin-give %s %d call=%s coin %s -> %s%s", method, n, tostring(ok), tostring(before), tostring(now), ok and "" or (" err=" .. tostring(err))))
      -- Log-only read, runs on any map (AfterAny).
      AfterAny(700, function() GameNow(function() local _, later = GoblinPlayerCoin(); print(string.format("[Reforged] coin-give %s 0.7 s later: %s", method, tostring(later))) end) end)
      GOBLIN_COIN_METHOD = method
    end)
  elseif op == "route-forks" then
    GameNow(RouteForks)
  elseif op == "route-weights" then
    GameNow(RouteWeights)
  elseif op == "route-set" then
    local p, b, w = tonumber(arg1), tonumber(arg2), tonumber(arg3)
    if not p or not b or not w then
      print("[Reforged] command rejected: route-set needs <pointIndex> <branchIndex> <weight>")
      return
    end
    GameNow(function() RouteSet(p, b, w) end)
  elseif op == "route-reload" then
    local n = tonumber(arg1)
    if not n or n < 0 then
      print("[Reforged] command rejected: route-reload needs a count of controllers")
      return
    end
    GameNow(function() RouteReload(n) end)
  elseif op == "spawn-center" then
    if arg1 == "true" then SPAWN_CENTER = true elseif arg1 == "false" then SPAWN_CENTER = false else SPAWN_CENTER = nil end
    print("[Reforged] spawn-center override=" .. tostring(SPAWN_CENTER))
  elseif op == "coordinators" then
    GameNow(function()
      local ok, list = pcall(FindAllOf, "OMDOnslaughtCoordinator")
      local first = coordinator()
      print("[Reforged] coordinators count=" .. tostring(ok and list and #list or "?") .. " first=" .. tostring(first and first:GetFullName() or "nil"))
      for i, c in ipairs(ok and list or {}) do
        pcall(function()
          local function g(fn) local o, v = pcall(fn); return o and tostring(v) or "?" end
          print(string.format("[Reforged] coordinator #%d valid=%s rift=%s iter=%s alive=%s approved=%s %s", i, tostring(c:IsValid()),
            g(function() return c.RiftPoints end), g(function() return c:GetEndlessIteration() end),
            g(function() return c:GetNumPawnsAlive() end), g(function() return c:GetNumPawnsApprovedForSpawn() end), c:GetFullName() .. " DefaultWaveTimer=" .. g(function() return c.DefaultWaveTimer end)))
        end)
      end
    end)
  elseif op == "route-where" then
    GameNow(RouteWhere)
  elseif op == "player-state" then
    GameNow(PlayerState)
  elseif op == "look" then
    -- Test only: set the player controller's rotation. Pitch and yaw are numbers in degrees. A positive pitch looks up.
    local pitch, yaw = tonumber(arg1), tonumber(arg2)
    if not pitch or not yaw then
      print("[Reforged] command rejected: look needs <pitch> <yaw>")
      return
    end
    GameNow(function()
      local okF, pc = pcall(function() return FindFirstOf("OMDPlayerController") end)
      if not okF or not pc then
        print(string.format("[Reforged] look pitch=%s yaw=%s ok=false err=no player controller", tostring(pitch), tostring(yaw)))
        return
      end
      local ok, err = pcall(function() pc:SetControlRotation({ Pitch = pitch, Yaw = yaw, Roll = 0 }) end)
      print(string.format("[Reforged] look pitch=%s yaw=%s ok=%s%s", tostring(pitch), tostring(yaw), tostring(ok), ok and "" or (" err=" .. tostring(err))))
    end)
  elseif op == "walk" then
    -- Test only (#100): adds movement input for seconds at yaw (degrees) to the player pawn, one tick every 50 ms.
    -- bForce is true. Prints the start and end location and the 2D distance moved. Synthetic keys do not reach the game under Wine.
    local yaw, secs = tonumber(arg1), tonumber(arg2)
    if not yaw or not secs or secs < 0.1 or secs > 30 then
      print("[Reforged] command rejected: walk needs <yaw> <seconds 0.1..30>")
      return
    end
    GameNow(function()
      local okF, pc = pcall(function() return FindFirstOf("OMDPlayerController") end)
      local okP, pawn = false, nil
      if okF and pc then okP, pawn = pcall(function() return pc.Pawn end) end
      if not okP or not pawn then
        print(string.format("[Reforged] walk yaw=%s seconds=%s ok=false err=no player pawn", tostring(yaw), tostring(secs)))
        return
      end
      local rad = math.rad(yaw)
      local dirX, dirY = math.cos(rad), math.sin(rad)
      local startLoc = WalkReadLoc(pawn)
      local okC, pawnClass = pcall(function() return pawn:GetClass():GetFullName() end)
      local okI, ignored = pcall(function() return pc:IsMoveInputIgnored() end)
      local okM, mode = pcall(function() return pawn.CharacterMovement.MovementMode end)
      print(string.format("[Reforged] walk pawn=%s moveIgnored=%s mode=%s",
        okC and tostring(pawnClass) or "?", okI and tostring(ignored) or "?", okM and tostring(mode) or "?"))
      local totalTicks = math.max(1, math.floor(secs * 20 + 0.5))
      local ticks, allOk, lastErr, firstErr = 0, true, nil, nil
      GameLoop(50, function()
        ticks = ticks + 1
        -- #70: the pawn can be freed during the walk (map change, death). Stop the loop when it is not valid.
        local okV, valid = pcall(function() return pawn:IsValid() end)
        if not okV or valid ~= true then
          print(string.format("[Reforged] walk yaw=%s seconds=%s ok=false err=pawn invalid", tostring(yaw), tostring(secs)))
          return true
        end
        local ok, err = pcall(function() pawn:AddMovementInput({ X = dirX, Y = dirY, Z = 0 }, 1.0, true) end)
        if not ok then
          allOk, lastErr = false, err
          firstErr = firstErr or err
        end
        if ticks < totalTicks then return false end
        local endLoc = WalkReadLoc(pawn)
        local moved = 0
        if startLoc and endLoc then
          moved = math.sqrt((endLoc.X - startLoc.X) ^ 2 + (endLoc.Y - startLoc.Y) ^ 2)
        end
        print(string.format("[Reforged] walk yaw=%s seconds=%s start=%s end=%s moved=%.0f ok=%s%s%s",
          tostring(yaw), tostring(secs), WalkFormatLoc(startLoc), WalkFormatLoc(endLoc), moved, tostring(allOk),
          allOk and "" or (" err=" .. tostring(lastErr)),
          firstErr and (" firstErr=" .. tostring(firstErr)) or ""))
        return true
      end)
    end)
  elseif op == "push" then
    -- Test only (#100): one LaunchCharacter at yaw (degrees) with speed. Prints the start and end location after 2000 ms.
    local yaw, speed = tonumber(arg1), tonumber(arg2)
    if not yaw or not speed or speed < 100 or speed > 5000 then
      print("[Reforged] command rejected: push needs <yaw> <speed 100..5000>")
      return
    end
    GameNow(function()
      local okF, pc = pcall(function() return FindFirstOf("OMDPlayerController") end)
      local okP, pawn = false, nil
      if okF and pc then okP, pawn = pcall(function() return pc.Pawn end) end
      if not okP or not pawn then
        print(string.format("[Reforged] push yaw=%s speed=%s ok=false err=no player pawn", tostring(yaw), tostring(speed)))
        return
      end
      local rad = math.rad(yaw)
      local startLoc = WalkReadLoc(pawn)
      local okL, err = pcall(function()
        pawn:LaunchCharacter({ X = math.cos(rad) * speed, Y = math.sin(rad) * speed, Z = 0 }, true, true)
      end)
      GameDelay(2000, function()
        -- #70: the pawn can be freed during the delay. Read its end location only when it is still valid.
        local okV, valid = pcall(function() return pawn:IsValid() end)
        local endLoc = nil
        if okV and valid == true then endLoc = WalkReadLoc(pawn) end
        local moved = 0
        if startLoc and endLoc then
          moved = math.sqrt((endLoc.X - startLoc.X) ^ 2 + (endLoc.Y - startLoc.Y) ^ 2)
        end
        local pawnErr = (okV and valid == true) and "" or " err=pawn invalid"
        print(string.format("[Reforged] push yaw=%s speed=%s start=%s end=%s moved=%.0f ok=%s%s%s",
          tostring(yaw), tostring(speed), WalkFormatLoc(startLoc), WalkFormatLoc(endLoc), moved, tostring(okL),
          okL and "" or (" err=" .. tostring(err)), pawnErr))
      end)
    end)
  elseif op == "go" then
    GameNow(GoBreakCommand)
  elseif op == "fn-dump" then
    GameNow(FnDump)
  elseif op == "go2" then
    GameNow(GameStateGoBreak)
  elseif op and op ~= "" then
    print("[Reforged] command rejected: use spawn <AIProto> <count>, random <count>, mix ProtoA=2,ProtoB=3, wave-amount <count>, wave-class <AIProto>, spawn-at <AIProto> <count> <doorIndex>, probe <guid|self|from> <AIProto|-> <count> <doorIndex> [rank], proto-check <AIProto>, inspect-protos, inspect-doors, status, placement-open on|off, hoard-gate on|off, hook-trace on|off")
  end
end

-- Resolve the installed Win64 directory through UE4SS. Unreal/Steam may change
-- the process working directory, so do not assume a relative path here.
local function ResolveDirectorCommandPath()
  local ok, directories = pcall(IterateGameDirectories)
  if not ok or type(directories) ~= "table" then return nil end
  for _, game in pairs(directories) do
    local binaries = game and game.Binaries
    local win64 = binaries and binaries.Win64
    local path = win64 and win64.__absolute_path
    if path and tostring(path) ~= "" then
      local normalized = tostring(path):gsub("\\", "/"):lower()
      if normalized:match("/omd/binaries/win64$") then
        return tostring(path) .. "/Mods/Reforged/director.cmd"
      end
    end
  end
  return nil
end

-- Stock replay wave source. Loads stock_waves.lua from require, else from <Win64>/ue4ss/Mods/Reforged/Scripts. A load failure
-- prints one line; ReforgedPlan then uses the generator for every round.
do
  local lib, errText = nil, nil
  local okReq, req = pcall(require, "stock_waves")
  if okReq and type(req) == "table" then
    lib = req
  else
    errText = okReq and "require returned no table" or tostring(req)
    local cmdPath = ResolveDirectorCommandPath()
    local win64Dir = cmdPath and cmdPath:match("^(.*)/Mods/Reforged/director%.cmd$")
    if win64Dir then
      local okFile, res = pcall(dofile, win64Dir .. "/ue4ss/Mods/Reforged/Scripts/stock_waves.lua")
      if okFile and type(res) == "table" then
        lib, errText = res, nil
      else
        errText = okFile and "dofile returned no table" or tostring(res)
      end
    else
      errText = tostring(errText) .. "; no Win64 path"
    end
  end
  if lib ~= nil and type(lib.levels) == "table" then
    REFORGED_STOCK.lib = lib
    REFORGED_STOCK.loadErr = nil
    local n = 0
    for _ in pairs(lib.levels) do n = n + 1 end
    print(string.format("[Reforged] stock waves loaded=true levels=%d", n))
  else
    REFORGED_STOCK.lib = nil
    REFORGED_STOCK.loadErr = errText or "no levels table"
    print("[Reforged] stock waves loaded=false err=" .. tostring(REFORGED_STOCK.loadErr))
  end
end

-- Wave modifiers. Loads modifiers.lua from require, else from <Win64>/ue4ss/Mods/Reforged/Scripts. A load failure
-- prints one line and leaves REFORGED_PLAN_HOOK nil, so the plans stay stock. The hook is a closure; no new main-chunk local.
do
  local lib, errText = nil, nil
  local okReq, req = pcall(require, "modifiers")
  if okReq and type(req) == "table" then
    lib = req
  else
    errText = okReq and "require returned no table" or tostring(req)
    local cmdPath = ResolveDirectorCommandPath()
    local win64Dir = cmdPath and cmdPath:match("^(.*)/Mods/Reforged/director%.cmd$")
    if win64Dir then
      local okFile, res = pcall(dofile, win64Dir .. "/ue4ss/Mods/Reforged/Scripts/modifiers.lua")
      if okFile and type(res) == "table" then
        lib, errText = res, nil
      else
        errText = okFile and "dofile returned no table" or tostring(res)
      end
    else
      errText = errText .. "; no Win64 path"
    end
  end
  if lib ~= nil then
    REFORGED_MOD.lib = lib
    REFORGED_MOD.loadErr = nil
    -- The hook runs once per round plan (ReforgedPlan). A forced id wins once; else the seeded roll decides.
    REFORGED_PLAN_HOOK = function(plan, ctx)
      if REFORGED_MOD.preview ~= true then HUD_BANNER.pending = nil end -- A real plan replaces the banner of the last one
      -- A plan built before map-ready has seed 0. It keeps the forced id for the real round plan.
      if ctx.seed == nil or ctx.seed == 0 then
        print(string.format("[Reforged] modifier skipped round=%s: plan before map ready (seed 0)", tostring(ctx.round)))
        return plan
      end
      local waves = REFORGED_WAVES
      local rollCtx = { round = ctx.round, seed = ctx.seed, cap = ctx.cap, mode = ctx.mode,
        boss = ReforgedIsBossRound(ctx.round) }
      local id, forced = nil, false
      local preview = REFORGED_MOD.preview == true
      if REFORGED_MOD.forced ~= nil then
        id, forced = REFORGED_MOD.forced, true
        if not preview then REFORGED_MOD.forced = nil end
      elseif REFORGED_MOD.on == true then
        id = lib.Roll(rollCtx, { chance = REFORGED_MOD.chance, minRound = REFORGED_MOD.minRound, last = REFORGED_MOD.last })
      end
      if id == nil then
        if not preview then REFORGED_MOD.last = nil end
        local s = lib.Summary(plan, plan)
        if preview then return plan end
        WatchEmit("modifier", { round = ctx.round, id = WatchNull, kind = WatchNull, forced = false,
          entriesBefore = s.entriesBefore, entriesAfter = s.entriesAfter, pawnsBefore = s.pawnsBefore, pawnsAfter = s.pawnsAfter })
        return plan
      end
      local out, err = lib.Apply(id, plan, ctx)
      if out == nil then
        print("[Reforged] modifier failed: " .. tostring(err))
        return plan
      end
      local s = lib.Summary(plan, out)
      if preview then
        print(string.format("[Reforged] modifier round=%s id=%s forced=%s entries=%s->%s pawns=%s->%s preview=true", tostring(ctx.round),
          tostring(id), tostring(forced), tostring(s.entriesBefore), tostring(s.entriesAfter), tostring(s.pawnsBefore), tostring(s.pawnsAfter)))
        return out
      end
      REFORGED_MOD.last = id
      HUD_BANNER.pending = { round = ctx.round, id = id, boss = rollCtx.boss == true } -- Shown at this round's combat start
      if PHASE_NOW ~= "combat" then -- A plan made in the break shows its popup now. A plan in combat keeps the combat start.
        local okS, sh = pcall(ModifierBannerAtBreak, id, ctx.round)
        if okS and sh == true then HUD_BANNER.pending.shown = true end
      end
      local rec = lib.Get(id)
      WatchEmit("modifier", { round = ctx.round, id = id, kind = rec and rec.kind or WatchNull, forced = forced,
        entriesBefore = s.entriesBefore, entriesAfter = s.entriesAfter, pawnsBefore = s.pawnsBefore, pawnsAfter = s.pawnsAfter })
      print(string.format("[Reforged] modifier round=%s id=%s forced=%s entries=%s->%s pawns=%s->%s", tostring(ctx.round), tostring(id),
        tostring(forced), tostring(s.entriesBefore), tostring(s.entriesAfter), tostring(s.pawnsBefore), tostring(s.pawnsAfter)))
      return out
    end
    print("[Reforged] modifiers loaded=true count=" .. tostring(#lib.List()))
  else
    REFORGED_MOD.loadErr = errText
    print("[Reforged] modifiers loaded=false " .. tostring(errText))
  end
end

-- Custom maps (#93). custom_map.lua runs the spawns, the mission borrow and the enemy routes on the Test maps in its MAPS table.
-- Loads from require, else from <Win64>/ue4ss/Mods/Reforged/Scripts. A load failure prints one line and nothing runs.
-- One do ... end block, no main-chunk local. Start gets the globals it needs, read at call time for the flags.
do
  local okReq, req = pcall(require, "custom_map")
  local lib, errText = nil, nil
  if okReq and type(req) == "table" then
    lib = req
  else
    errText = okReq and "require returned no table" or tostring(req)
    local cmdPath = ResolveDirectorCommandPath()
    local win64Dir = cmdPath and cmdPath:match("^(.*)/Mods/Reforged/director%.cmd$")
    if win64Dir then
      local okFile, res = pcall(dofile, win64Dir .. "/ue4ss/Mods/Reforged/Scripts/custom_map.lua")
      if okFile and type(res) == "table" then
        lib, errText = res, nil
      else
        errText = okFile and "dofile returned no table" or tostring(res)
      end
    else
      errText = errText .. "; no Win64 path"
    end
  end
  if lib ~= nil and type(lib.Start) == "function" then
    REFORGED_CUSTOM = { lib = lib, loadErr = nil }
    local okS, errS = pcall(lib.Start, {
      GameLoop = GameLoop, GameDelay = GameDelay, WatchEmit = WatchEmit, GuidFromString = GuidFromString,
      EndlessDifficulty = function() return ENDLESS_DIFFICULTY end,
      Testing = function() return TESTING == true end,
      TestMode = function() return TEST_MODE == true end,
      Diag = DiagOn,
      HubOpen = EndlessHubOpen, ConsoleExec = ConsoleExec, RegisterKeyBind = RegisterKeyBind, Key = Key,
    })
    if okS then
      print("[Reforged] custom-map loaded=true maps=" .. tostring(lib.MapCount()))
    else
      REFORGED_CUSTOM.loadErr = tostring(errS)
      print("[Reforged] custom-map loaded=false err=" .. tostring(errS))
    end
  else
    REFORGED_CUSTOM = { lib = nil, loadErr = errText }
    print("[Reforged] custom-map loaded=false " .. tostring(errText))
  end
end

-- #103 phase 1: the custom-map title card. The post-hook runs custom_map.lua OnIntroHook after the load screen hides.
-- The hook is registered only when the function exists (SafeRegisterHook). A nil lib does nothing. One do ... end block.
do
  local okI, errI = SafeRegisterHook("/Game/Game/BP_OMDGameInstance.BP_OMDGameInstance_C:HideLoadingScreen", function() end, function()
    local lib = REFORGED_CUSTOM and REFORGED_CUSTOM.lib
    if lib ~= nil and type(lib.OnIntroHook) == "function" then lib.OnIntroHook() end
  end)
  if not okI then print("[Reforged] custom-map intro hook not registered err=" .. tostring(errI)) end
end

-- Modifiers in Classic. Off unless the modifiersInClassic row is on.
-- The stock round runs as normal. A hit adds director door calls 10 s after combat starts, through the pace queue.
-- Globals only: the main chunk is near its local limit. gen drops a timer that belongs to an older match.
CLASSIC_MOD = { round = 0, gen = 0, last = nil }
function ClassicModMapReset()
  CLASSIC_MOD.round = 0
  CLASSIC_MOD.gen = CLASSIC_MOD.gen + 1
  CLASSIC_MOD.last = nil
  CLASSIC_MOD.next = nil -- A break roll of the last match
  CLASSIC_MOD.shownRound = nil -- The round whose popup the break showed
end
-- The doors a Classic modifier uses: the usable doors with bIsActive (the native round's doors), else every usable door.
-- Returns the sorted door indexes and the source ("native" or "any").
function ClassicModDoors()
  local active, usable = {}, {}
  local okF, list = pcall(FindAllOf, "OMDAISpawner")
  if okF and type(list) == "table" then
    for _, sp in ipairs(list) do
      pcall(function()
        local okI, raw = pcall(function() return tonumber(sp.indexInLevel) end)
        local index = okI and raw or nil
        if index == nil or index % 1 ~= 0 or DoorUsable(sp) ~= true then return end
        usable[#usable + 1] = index
        local okA, on = pcall(function() return sp.bIsActive end)
        if okA and on == true then active[#active + 1] = index end
      end)
    end
  end
  table.sort(usable)
  table.sort(active)
  if #active > 0 then return active, "native" end
  return usable, "any"
end
-- Called (pcall) from PhaseTick when the phase changes into a break. Rolls the coming round once and shows its popup.
-- ClassicModCombatStart uses this roll. It does nothing unless the Classic modifier setting is on.
function ClassicModBreakStart()
  CLASSIC_MOD.next = nil
  if QueueBlockMode() ~= "classic" or REFORGED_MOD.classic ~= "on" then return end
  local lib = REFORGED_MOD.lib
  if lib == nil then return end
  local r = CLASSIC_MOD.round + 1
  local id = lib.RollClassic({ round = r, seed = REFORGED.seed, mode = "classic", boss = false },
    { chance = REFORGED_MOD.chance, minRound = REFORGED_MOD.minRound, last = CLASSIC_MOD.last })
  CLASSIC_MOD.last = id
  CLASSIC_MOD.next = { round = r, id = id }
  if id == nil then return end
  print(string.format("[Reforged] classic modifier round=%d id=%s rolled at break", r, id))
  CLASSIC_MOD.shownRound = r -- ClassicModQueue does not show the popup again for this round
  pcall(ModifierBannerAtBreak, id, r)
end

-- Called from the watch tick when the phase changes into combat (PhaseTick). Uses the break roll of this round, else rolls once.
function ClassicModCombatStart()
  if QueueBlockMode() ~= "classic" then return end
  CLASSIC_MOD.round = CLASSIC_MOD.round + 1
  if REFORGED_MOD.classic ~= "on" then return end
  local r = CLASSIC_MOD.round
  local nxt = CLASSIC_MOD.next
  CLASSIC_MOD.next = nil
  local id = nil
  if nxt ~= nil and nxt.round == r then
    id = nxt.id -- Rolled at the break. Its popup is already shown.
  else
    local lib = REFORGED_MOD.lib
    if lib == nil then
      print(string.format("[Reforged] classic modifier round=%d skipped: modifier module not loaded", r))
      return
    end
    id = lib.RollClassic({ round = r, seed = REFORGED.seed, mode = "classic", boss = false },
      { chance = REFORGED_MOD.chance, minRound = REFORGED_MOD.minRound, last = CLASSIC_MOD.last })
    CLASSIC_MOD.last = id
  end
  if id == nil then return end
  local gen, seed = CLASSIC_MOD.gen, REFORGED.seed
  print(string.format("[Reforged] classic modifier round=%d id=%s hit, adds in 10 s", r, id))
  After(10000, function()
    RunOnGameThread("classic-modifier", function() ClassicModQueue(gen, r, id, seed) end)
  end)
end
-- Adds the Classic form of a modifier as door calls. Each entry i uses the door (i-1) mod #doors + 1. Calls go through the pace queue.
function ClassicModQueue(gen, r, id, seed)
  if gen ~= CLASSIC_MOD.gen or QueueBlockMode() ~= "classic" then
    print(string.format("[Reforged] classic modifier round=%d id=%s dropped: match or mode changed", r, tostring(id)))
    return
  end
  local lib = REFORGED_MOD.lib
  local form = lib and lib.Classic(id, { round = r, seed = seed }) or nil
  if form == nil then
    print(string.format("[Reforged] classic modifier round=%d id=%s has no classic form", r, tostring(id)))
    return
  end
  local doors, source = ClassicModDoors()
  if #doors == 0 then
    print(string.format("[Reforged] classic modifier round=%d id=%s no usable doors, added=0", r, tostring(id)))
    return
  end
  local added = {}
  for i, e in ipairs(form.entries) do
    local door = doors[(i - 1) % #doors + 1]
    local base = PROTO_BY_NAME[e.proto]
    if base == nil then
      print(string.format("[Reforged] classic modifier round=%d skipped unknown proto %s", r, tostring(e.proto)))
    else
      -- classicMod marks the call for the pace queue. classicCfg is the reinforce block a bearer keeps.
      local row = setmetatable({ classicMod = true, bearer = e.bearer == true, classicCfg = form.reinforce }, { __index = base })
      added[#added + 1] = WatchList({ e.proto, e.count })
      DoorSpawn(door, row, e.count)
    end
  end
  local rec = lib.Get(id)
  WatchEmit("modifier", { mode = "classic", round = r, id = id, kind = rec and rec.kind or WatchNull, forced = false,
    entries = WatchList(added), source = source })
  print(string.format("[Reforged] classic modifier round=%d id=%s added=%d", r, tostring(id), #added))
  if CLASSIC_MOD.shownRound ~= r then pcall(ModBannerClassic, id, r) end -- The banner when the calls are added. Not after the break popup
end

-- Modifier banner. The stock EndlessWave_UMG widget shows a title and an optional second line, then removes itself
-- after 1.75 s. Every game call runs on the game thread (GameNow, GameDelay) and in pcall. The title and line are passed as FText.
-- Globals and one do block only: the main chunk is near its local limit.
do
  local BANNER_CLASS = "/Game/UI/PlayerHUD/EndlessWave_UMG.EndlessWave_UMG_C"
  local TITLE_Y, LINE_Y = 110, 190
  local BANNER_DELAY_MS = 2500

  local function bannerValid(o)
    local ok, v = pcall(function() return o ~= nil and o:IsValid() == true end)
    return ok and v == true
  end

  -- The modifier popup sits below the centre, at about 60 % and 50 % of the stock text size.
  -- It stays from the break start until combat starts. MOD_BANNER_HOLD_MS is the cap.
  -- MOD_BANNER_FALLBACK_HOLD_MS is the hold of a popup shown during combat.
  MOD_BANNER_TITLE_Y = 320
  MOD_BANNER_LINE_Y = 380
  MOD_BANNER_TITLE_SCALE = 0.6
  MOD_BANNER_LINE_SCALE = 0.5
  MOD_BANNER_HOLD_MS = 20000
  MOD_BANNER_FALLBACK_HOLD_MS = 3000

  -- The opts table for HudBannerShow and BannerLong. A new table each call. holdMs (optional) replaces the break hold.
  function ModBannerOpts(holdMs)
    return { titleY = MOD_BANNER_TITLE_Y, lineY = MOD_BANNER_LINE_Y, titleScale = MOD_BANNER_TITLE_SCALE,
      lineScale = MOD_BANNER_LINE_SCALE, holdMs = holdMs or MOD_BANNER_HOLD_MS }
  end

  -- Sets the text size of one text widget to scale times its size. Returns the size read back and the old size,
  -- or nil when the old size is not readable (SetFont is then not called). baseSize (optional) is the old size: a re-add
  -- passes it, so the scale does not apply twice. Each game read and the SetFont call run in pcall.
  function BannerFontScale(textBlock, scale, baseSize)
    local function rd(fn)
      local okR, v = pcall(fn)
      if okR then return v end
      return nil
    end
    local old = baseSize
    if type(old) ~= "number" then old = rd(function() return textBlock.Font.Size end) end
    if type(old) ~= "number" or old <= 0 then return nil end
    local fo = rd(function() return textBlock.Font.FontObject end)
    local face = rd(function() return textBlock.Font.TypefaceFontName end)
    local spacing = rd(function() return textBlock.Font.LetterSpacing end)
    local mat = rd(function() return textBlock.Font.FontMaterial end)
    local outline = {
      OutlineSize = rd(function() return textBlock.Font.OutlineSettings.OutlineSize end),
      OutlineMaterial = rd(function() return textBlock.Font.OutlineSettings.OutlineMaterial end),
      OutlineColor = {
        R = rd(function() return textBlock.Font.OutlineSettings.OutlineColor.R end),
        G = rd(function() return textBlock.Font.OutlineSettings.OutlineColor.G end),
        B = rd(function() return textBlock.Font.OutlineSettings.OutlineColor.B end),
        A = rd(function() return textBlock.Font.OutlineSettings.OutlineColor.A end),
      },
    }
    local newSize = math.max(8, math.floor(old * scale + 0.5))
    local okSet = pcall(function()
      textBlock:SetFont({ FontObject = fo, TypefaceFontName = face, Size = newSize, LetterSpacing = spacing or 0,
        FontMaterial = mat, OutlineSettings = outline })
    end)
    if not okSet then return nil, old end
    return rd(function() return textBlock.Font.Size end), old
  end

  -- Builds the banner widgets. Errors stop it at st.step. st.line is none, shown or skipped. st.offset is the title offset result.
  -- The second line is created and moved before it is added: when its offset call fails, the line is skipped.
  -- St.opts (optional) gives st.ty and st.ly as the Y offsets, and the font scales. st.style[1] and [2] hold the used values.
  local function bannerWidgets(pc, title, line, st)
    st.step = "class"
    local cls = StaticFindObject(BANNER_CLASS)
    if not bannerValid(cls) then
      pcall(LoadAsset, BANNER_CLASS)
      cls = StaticFindObject(BANNER_CLASS)
    end
    if not bannerValid(cls) then error("class not found: " .. BANNER_CLASS) end
    st.step = "library"
    local wbl = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    if not bannerValid(wbl) then error("widget library not found") end
    st.step = "create"
    local w = wbl:Create(pc, cls, pc)
    if not bannerValid(w) then error("create returned no widget") end
    st.step = "viewport"
    w:AddToViewport(50)
    st.widgets = { w } -- The widgets HudBannerHoldLast can hold
    st.step = "text"
    w.Wave:SetText(FText(title))
    st.style = st.style or {}
    if st.opts ~= nil and st.opts.titleScale ~= nil then
      local sz, base = BannerFontScale(w.Wave, st.opts.titleScale)
      st.style[1] = { y = st.ty, scale = st.opts.titleScale, base = base, size = sz }
    end
    st.offset = pcall(function() w:SetRenderTranslation({ X = 0, Y = st.ty or TITLE_Y }) end)
    if line ~= nil then
      st.step = "line-create"
      local w2 = wbl:Create(pc, cls, pc)
      if not bannerValid(w2) then error("line create returned no widget") end
      st.step = "line-offset"
      if pcall(function() w2:SetRenderTranslation({ X = 0, Y = st.ly or LINE_Y }) end) then
        st.step = "line-viewport"
        w2:AddToViewport(50)
        st.widgets[2] = w2
        st.step = "line-text"
        w2.Wave:SetText(FText(line))
        if st.opts ~= nil and st.opts.lineScale ~= nil then
          local sz2, base2 = BannerFontScale(w2.Wave, st.opts.lineScale)
          st.style[2] = { y = st.ly, scale = st.opts.lineScale, base = base2, size = sz2 }
        end
        st.line = "shown"
      else
        st.line = "skipped"
      end
    end
  end

  -- Shows the banner now. The developer command `banner <text>` calls it with line nil. Returns true when every step ran.
  -- Opts (optional) is { titleY, lineY, titleScale, lineScale }. Without it the stock Y offsets and sizes are kept.
  function HudBannerShow(title, line, opts)
    HUD_BANNER.last = {} -- Cleared at each show; set again below when the widgets are made
    HUD_BANNER.lastStyle = {} -- The Y and scale of each widget, for a re-add
    if type(opts) ~= "table" then opts = nil end
    if HUD_BANNER.on ~= true then
      print("[Reforged] banner skipped reason=setting-off")
      return false
    end
    if type(title) ~= "string" or title == "" then
      print("[Reforged] banner skipped reason=empty-text")
      return false
    end
    if line == "" then line = nil end
    local pc = nil
    pcall(function() pc = FindFirstOf("OMDPlayerController") end)
    if not bannerValid(pc) then
      print("[Reforged] banner skipped reason=no-controller")
      return false
    end
    local ty, ly = TITLE_Y, LINE_Y
    if opts ~= nil then ty = tonumber(opts.titleY) or ty; ly = tonumber(opts.lineY) or ly end
    local st = { step = "none", line = "none", offset = nil, opts = opts, ty = ty, ly = ly, style = {} }
    local ok, err = pcall(bannerWidgets, pc, title, line, st)
    if not ok then print("[Reforged] banner error step=" .. tostring(st.step) .. " err=" .. tostring(err)) end
    if st.offset == false then print("[Reforged] banner title offset unavailable, stock place kept") end
    local okAll = ok == true
    HUD_BANNER.last = (okAll and (st.widgets or {})) or {} -- A failed show holds nothing
    HUD_BANNER.lastY = { ty, ly } -- The Y offsets of HUD_BANNER.last[1] and [2]
    HUD_BANNER.lastStyle = st.style
    local step = okAll and "done" or st.step
    print(string.format("[Reforged] banner ok=%s step=%s title=%s line=%s", tostring(okAll), tostring(step), title, st.line))
    WatchEmit("ui", { screen = "hud", action = "banner", ok = okAll, title = title,
      line = (line ~= nil) and line or WatchNull, step = step, lineState = st.line, offset = st.offset == true })
    return okAll
  end

  -- Holds a widget on the solid part of its stock animation (BANNER_PLATEAU_T), then pauses it there.
  -- Returns true when both calls worked. Each game call is in pcall.
  function BannerPlateau(w)
    local okA, a = pcall(function() return w.Animate end)
    if not okA then return false end
    local okT = pcall(function() w:SetAnimationCurrentTime(a, BANNER_PLATEAU_T) end)
    local okP = pcall(function() w:PauseAnimation(a) end)
    return okT and okP
  end

  -- Holds the last banner on its plateau.
  -- Returns "ok" when every widget worked, "failed" when any call raised, "none" when there is no widget.
  function HudBannerHoldLast()
    local list = HUD_BANNER.last or {}
    if #list == 0 then return "none" end
    local res = "ok"
    for _, w in ipairs(list) do
      if not BannerPlateau(w) then res = "failed" end
    end
    return res
  end

  -- The level-load popup comes back once. The stock banner removes itself after its 1.75 s Delay. A post hook on
  -- RemoveFromParent adds the same widget again, sets its text and Y, and holds it on its plateau.
  -- Entries of the popups are in HUD_BANNER.readd. Each entry is re-added once per removal (left).
  local function ReaddOne(e)
    local okA = pcall(function() e.w:AddToViewport(50) end)
    local okT = pcall(function() e.w.Wave:SetText(FText(e.text)) end)
    local okO = pcall(function() e.w:SetRenderTranslation({ X = 0, Y = e.y }) end)
    local okH = BannerPlateau(e.w)
    -- A hold entry is not faded or removed here. Its hold timer ends it.
    local okAll = okA and okT and okO and okH
    if e.scale ~= nil then -- The font scale of the first show, from its old size
      pcall(function() BannerFontScale(e.w.Wave, e.scale, e.base) end)
    end
    print(string.format("[Reforged] mode-banner readd ok=%s widget=%s", tostring(okAll), e.kind))
    if okAll and e.hold ~= true then -- A hold entry ends at its hold timer, not at this backstop
      -- Backstop: the re-add has no Construct timer of its own. After 4 s, a widget still in the viewport is removed.
      pcall(GameDelay, 4000, function()
        if not bannerValid(e.w) then return end
        local okV, inVp = pcall(function() return e.w:IsInViewport() == true end)
        if not (okV and inVp) then return end
        pcall(function() e.w:RemoveFromParent() end)
        print("[Reforged] mode-banner backstop removed widget=" .. tostring(e.kind))
      end)
    end
  end

  -- The post hook body. self:get() is the widget that called RemoveFromParent. Returns at once when the list is empty.
  function ModeBannerReaddHook(self)
    local list = HUD_BANNER.readd
    if type(list) ~= "table" or #list == 0 then return end
    local okW, cw = pcall(function() return self:get() end)
    if not okW or cw == nil then return end
    local okC, ca = pcall(function() return cw:GetAddress() end)
    if not okC or ca == nil then return end
    for _, e in ipairs(list) do
      if e.left > 0 then
        local okE, ea = pcall(function() return e.w:GetAddress() end)
        if okE and ea == ca then
          e.left = e.left - 1
          ReaddOne(e)
        end
      end
    end
    local open = false
    for _, e in ipairs(list) do
      if e.left > 0 then open = true end
    end
    if not open then HUD_BANNER.readd = {} end
  end

  -- Registers the RemoveFromParent post hook once. Sets HUD_BANNER.readdOk. Runs at load.
  function ModeBannerReaddRegister()
    if HUD_BANNER.readdHooked == true then return end
    HUD_BANNER.readdHooked = true
    local okR, regOk = pcall(SafeRegisterHook, "/Script/UMG.Widget:RemoveFromParent", function() end, ModeBannerReaddHook)
    HUD_BANNER.readdOk = (okR and regOk == true)
    print("[Reforged] mode-banner readd hook registered=" .. tostring(HUD_BANNER.readdOk))
  end
  HUD_BANNER.readd = {}
  ModeBannerReaddRegister()

  -- The delay in ms: 2500 on a boss round, and on a round that is a multiple of 5 at difficulty 3. Else 0.
  function ModBannerDelay(round, boss)
    if boss == true then return BANNER_DELAY_MS end
    local r = tonumber(round)
    if r ~= nil and r % 5 == 0 and ReadGameDifficulty() == 3 then return BANNER_DELAY_MS end
    return 0
  end

  -- Ends the hold entries of one tag that are not expired yet (left > 0). reason is "combat" or "cap".
  -- Each entry is marked expired first, so the RemoveFromParent hook does not add it back. Then each widget still in the
  -- viewport gets the fade-out: PlayAnimation from BANNER_FADEOUT_T, then removal 450 ms later
  -- when it is still in the viewport. If PlayAnimation raises, it is removed at once.
  -- The log line prints once, and only when at least one entry ended.
  -- holdId (optional): when given, only the entries of that BannerLong call end. Else all entries of the tag.
  function BannerHoldEnd(tag, reason, holdId)
    local list = HUD_BANNER.readd
    if type(list) ~= "table" then return end
    local ended = {}
    for _, e in ipairs(list) do
      if e.hold == true and e.tag == tag and e.left > 0 and (holdId == nil or e.holdId == holdId) then
        e.left = 0
        e.untilAt = true
        ended[#ended + 1] = e
      end
    end
    for _, e in ipairs(ended) do
      if bannerValid(e.w) then
        local okV, inVp = pcall(function() return e.w:IsInViewport() == true end)
        if okV and inVp then
          local okP = pcall(function() e.w:PlayAnimation(e.w.Animate, BANNER_FADEOUT_T, 1, 0, 1.0, false) end)
          if okP then
            pcall(GameDelay, 450, function()
              if not bannerValid(e.w) then return end
              local okV2, inVp2 = pcall(function() return e.w:IsInViewport() == true end)
              if okV2 and inVp2 then pcall(function() e.w:RemoveFromParent() end) end
            end)
          else
            pcall(function() e.w:RemoveFromParent() end)
          end
        end
      end
    end
    if #ended > 0 then
      print("[Reforged] banner long tag=" .. tostring(tag) .. " hold ended reason=" .. tostring(reason))
    end
  end

  -- Shows the level-load or modifier popup long and steady (the re-add). tag names the popup in the log.
  -- Appends its widgets to HUD_BANNER.readd when the hook registered. Else runs the second pass.
  -- Returns true when HudBannerShow ran and returned true.
  -- Opts (optional) is passed to HudBannerShow. With opts.holdMs, the entries are re-added until the hold timer ends them.
  -- The hold timer marks them expired, then removes each widget still in the viewport. An expired entry is not re-added.
  function BannerLong(title, line, tag, opts)
    local addr1 = ModeBannerStateAddress()
    local okB, res = pcall(HudBannerShow, title, line, opts)
    local shown = (okB and res == true)
    print(string.format("[Reforged] banner long tag=%s shown=%s", tostring(tag), tostring(shown)))
    if shown and HUD_BANNER.readdOk == true then
      -- The hook adds these widgets back when the stock banner removes them. No second pass.
      local ws = HUD_BANNER.last or {}
      local ys = HUD_BANNER.lastY or {}
      local ss = HUD_BANNER.lastStyle or {}
      local holdMs = (type(opts) == "table") and tonumber(opts.holdMs) or nil
      if type(HUD_BANNER.readd) ~= "table" then HUD_BANNER.readd = {} end
      local holdId = nil -- A unique id per call with a hold, so its timer ends only its own entries
      if holdMs ~= nil then
        HUD_BANNER.holdSeq = (HUD_BANNER.holdSeq or 0) + 1
        holdId = HUD_BANNER.holdSeq
      end
      local made = {}
      if ws[1] ~= nil and ys[1] ~= nil then
        made[#made + 1] = { w = ws[1], text = title, y = ys[1], left = 1, kind = "title", scale = (ss[1] or {}).scale, base = (ss[1] or {}).base }
      end
      if line ~= nil and ws[2] ~= nil and ys[2] ~= nil then
        made[#made + 1] = { w = ws[2], text = line, y = ys[2], left = 1, kind = "line", scale = (ss[2] or {}).scale, base = (ss[2] or {}).base }
      end
      if holdMs ~= nil then
        for _, e in ipairs(made) do e.left = math.huge; e.hold = true; e.untilAt = false; e.tag = tag; e.holdId = holdId end
      end
      for _, e in ipairs(made) do HUD_BANNER.readd[#HUD_BANNER.readd + 1] = e end
      if holdMs ~= nil then
        pcall(GameDelay, holdMs, function() BannerHoldEnd(tag, "cap", holdId) end)
      end
      -- The first pass is held on its plateau after the fade-in, so the stock 1.75 s removal does not fade it.
      if #made > 0 then
        pcall(GameDelay, BANNER_PLATEAU_DELAY_MS, function()
          local n, allOk = 0, true
          for _, e in ipairs(made) do
            if e.left > 0 and bannerValid(e.w) then
              local okV, inVp = pcall(function() return e.w:IsInViewport() == true end)
              if okV and inVp then
                n = n + 1
                if not BannerPlateau(e.w) then allOk = false end
              end
            end
          end
          print(string.format("[Reforged] banner plateau tag=%s widgets=%d ok=%s", tostring(tag), n, tostring(allOk)))
        end)
      end
    elseif shown then
      local name = (tag == "mode") and "mode-banner" or ("banner-" .. tostring(tag))
      pcall(GameDelay, MODE_BANNER_PASS2_MS, function()
        local addr2 = ModeBannerStateAddress()
        if addr2 == nil or addr2 ~= addr1 then
          print("[Reforged] " .. name .. " pass=2 skipped reason=map")
          return
        end
        local okS, shown2 = pcall(HudBannerShow, title, line, opts)
        local okH, hold = pcall(HudBannerHoldLast)
        if not okH then hold = "failed" end
        print(string.format("[Reforged] %s pass=2 shown=%s hold=%s", name, tostring(okS and shown2 == true), tostring(hold)))
      end)
    end
    return shown
  end

  -- The modifier popup at the start of the break. It waits until 4 s after the level-load popup.
  -- Returns true when the popup is shown or scheduled.
  function ModifierBannerAtBreak(id, round)
    local lib = REFORGED_MOD.lib
    local title, line = nil, nil
    if lib ~= nil then title, line = lib.Banner(id) end
    if title == nil then return false end
    local wait_ms = 0
    local at = HUD_BANNER.modeShownAt
    if at ~= nil then
      wait_ms = math.max(0, (4 - (os.time() - at)) * 1000)
    end
    local function show()
      print(string.format("[Reforged] modifier banner at break round=%s id=%s", tostring(round), tostring(id)))
      BannerLong(title, line, "modifier", ModBannerOpts())
    end
    if wait_ms > 0 then
      pcall(GameDelay, wait_ms, show)
    else
      GameNow(show)
    end
    return true
  end

  -- Shows the banner now (delayMs 0) or after delayMs. Both run HudBannerShow on the game thread.
  -- The modifier popup of the combat start and the Classic adds. It uses the same size, place and hold as the break popup.
  function ModBannerShowAt(title, line, delayMs)
    local function show() BannerLong(title, line, "modifier", ModBannerOpts(MOD_BANNER_FALLBACK_HOLD_MS)) end
    if delayMs > 0 then
      GameDelay(delayMs, show)
    else
      GameNow(show)
    end
  end

  -- Reforged: called when the phase changes into combat (PhaseTick). Shows the banner of the rolled id once, then clears it.
  function ModBannerCombatStart()
    local p = HUD_BANNER.pending
    HUD_BANNER.pending = nil
    if p == nil or p.shown == true then return end -- The break showed this popup
    local lib = REFORGED_MOD.lib
    local title, line = nil, nil
    if lib ~= nil then title, line = lib.Banner(p.id) end
    if title == nil then
      print("[Reforged] banner skipped reason=no-text id=" .. tostring(p.id))
      return
    end
    local delay = ModBannerDelay(p.round, p.boss)
    print(string.format("[Reforged] banner round=%s id=%s delay=%d", tostring(p.round), tostring(p.id), delay))
    ModBannerShowAt(title, line, delay)
  end

  -- Classic: called when a hit adds its door calls (ClassicModQueue). The banner follows the adds.
  function ModBannerClassic(id, r)
    local lib = REFORGED_MOD.lib
    local title, line = nil, nil
    if lib ~= nil then title, line = lib.Banner(id) end
    if title == nil then return end
    local delay = ModBannerDelay(r, false)
    print(string.format("[Reforged] banner round=%s id=%s delay=%d", tostring(r), tostring(id), delay))
    ModBannerShowAt(title, line, delay)
  end
end

local function StepSpawn(door, row, count)
  DoorSpawn(door, row, count)
end

-- JSON wave file (format version 1): Mods/Reforged/waves/<name>.json, run with `wave-file <name>`.
-- {"formatVersion":1,"name":"...","steps":[{"atSeconds":0,"door":2,"proto":"OrcMedium","count":2}, ...]}
-- Each step is one door call (door index, AI proto, count 1-10) at atSeconds after the command. The file is checked before
-- anything runs; any error rejects the whole file. Steps on one door must be at least 10 s apart.
local function JsonDecode(str)
  local pos = 1
  local function ws() pos = str:find("[^ \t\r\n]", pos) or #str + 1 end
  local value
  local function fail(msg) error(string.format("JSON error at byte %d: %s", pos, msg), 0) end
  local function parseString()
    pos = pos + 1
    local out = {}
    while true do
      local c = str:sub(pos, pos)
      if c == "" then fail("unterminated string") end
      if c == '"' then pos = pos + 1; return table.concat(out) end
      if c == "\\" then
        local n = str:sub(pos + 1, pos + 1)
        local map = { n = "\n", t = "\t", r = "\r", ['"'] = '"', ["\\"] = "\\", ["/"] = "/" }
        if not map[n] then fail("unsupported escape") end
        out[#out + 1] = map[n]; pos = pos + 2
      else out[#out + 1] = c; pos = pos + 1 end
    end
  end
  function value()
    ws()
    local c = str:sub(pos, pos)
    if c == "{" then
      local obj = {}
      pos = pos + 1; ws()
      if str:sub(pos, pos) == "}" then pos = pos + 1; return obj end
      while true do
        ws()
        if str:sub(pos, pos) ~= '"' then fail("object key must be a string") end
        local k = parseString(); ws()
        if str:sub(pos, pos) ~= ":" then fail("expected :") end
        pos = pos + 1; obj[k] = value(); ws()
        local d = str:sub(pos, pos); pos = pos + 1
        if d == "}" then return obj end
        if d ~= "," then fail("expected , or }") end
      end
    elseif c == "[" then
      local arr = {}
      pos = pos + 1; ws()
      if str:sub(pos, pos) == "]" then pos = pos + 1; return arr end
      while true do
        arr[#arr + 1] = value(); ws()
        local d = str:sub(pos, pos); pos = pos + 1
        if d == "]" then return arr end
        if d ~= "," then fail("expected , or ]") end
      end
    elseif c == '"' then return parseString()
    elseif str:sub(pos, pos + 3) == "true" then pos = pos + 4; return true
    elseif str:sub(pos, pos + 4) == "false" then pos = pos + 5; return false
    elseif str:sub(pos, pos + 3) == "null" then pos = pos + 4; return nil
    else
      local num = str:match("^-?%d+%.?%d*[eE]?[+-]?%d*", pos)
      if not num or num == "" then fail("unexpected character") end
      pos = pos + #num; return tonumber(num)
    end
  end
  local result = value(); ws()
  if pos <= #str then fail("trailing data") end
  return result
end

-- Shared by wave-file and profile-run. Returns an error text, or nil plus the requested total and the last step time.
local function ValidateSteps(steps, label)
  local pre = label and (label .. ": ") or ""
  if type(steps) ~= "table" or #steps < 1 or #steps > 100 then return pre .. "steps must list 1 to 100 entries" end
  local lastAt, total, latest = {}, 0, 0
  for i, st in ipairs(steps) do
    if type(st) ~= "table" then return pre .. "step " .. i .. " is not an object" end
    for k in pairs(st) do
      if k ~= "atSeconds" and k ~= "door" and k ~= "proto" and k ~= "count" then return pre .. "step " .. i .. " has unsupported field " .. tostring(k) end
    end
    local at, door, count = st.atSeconds, st.door, st.count
    if type(at) ~= "number" or at < 0 or at > 600 then return pre .. "step " .. i .. " atSeconds must be 0 to 600" end
    if type(door) ~= "number" or door % 1 ~= 0 then return pre .. "step " .. i .. " door must be an integer" end
    if type(count) ~= "number" or count % 1 ~= 0 or count < 1 or count > 10 then return pre .. "step " .. i .. " count must be an integer from 1 to 10" end
    if type(st.proto) ~= "string" or not PROTO_BY_NAME[st.proto] then return pre .. "step " .. i .. " has unknown proto " .. tostring(st.proto) end
    if lastAt[door] and math.abs(at - lastAt[door]) < 10 then return pre .. "step " .. i .. " is less than 10 s after another step on door " .. door end
    lastAt[door] = at; total = total + count; if at > latest then latest = at end
  end
  return nil, total, latest
end

RunWaveFile = function(name)
  if not WAVE_COMMAND_PATH then print("[Reforged] wave-file rejected: command path not resolved"); return end
  if type(name) ~= "string" or not name:match("^[A-Za-z0-9_%-]+$") then
    print("[Reforged] wave-file rejected: name must use letters, digits, _ and - only"); return
  end
  local path = WAVE_COMMAND_PATH:gsub("director%.cmd$", "waves/" .. name .. ".json")
  local fh, ferr = io.open(path, "r")
  if not fh then print("[Reforged] wave-file rejected: cannot open " .. path .. " (" .. tostring(ferr) .. ")"); return end
  local text = fh:read("*a"); fh:close()
  local okJ, doc = pcall(JsonDecode, text)
  if not okJ then print("[Reforged] wave-file rejected: " .. tostring(doc)); return end
  local function reject(msg) print("[Reforged] wave-file rejected: " .. msg) end
  if type(doc) ~= "table" or doc.formatVersion ~= 1 then return reject("formatVersion must be 1") end
  local err, total, latest = ValidateSteps(doc.steps)
  if err then return reject(err) end
  WaveBegin("file " .. name, latest + 8)
  for _, st in ipairs(doc.steps) do
    local row, door, count = PROTO_BY_NAME[st.proto], st.door, st.count
    After(st.atSeconds * 1000, function() StepSpawn(door, row, count) end)
  end
  print(string.format("[Reforged] wave-file scheduled name=%s steps=%d requested_total=%d last_step_at=%ds", name, #doc.steps, total, latest))
end


-- Profile (format version 1): {"formatVersion":1,"breakSeconds":8,"waves":[{"steps":[...]},...]}, run with `profile-run <name>`.
-- The waves run in order. Each wave is a wave file's steps. When a wave ends (tracker: no tracked pawn alive), the director waits
-- breakSeconds and starts the next wave. The list is the whole schedule: waves not listed do not run. Pair it with `takeover on`.
local profileState = nil
RunProfile = function(name)
  local function reject(msg) print("[Reforged] profile rejected: " .. msg) end
  if not WAVE_COMMAND_PATH then return reject("command path not resolved") end
  if type(name) ~= "string" or not name:match("^[A-Za-z0-9_%-]+$") then return reject("name must use letters, digits, _ and - only") end
  if profileState and not profileState.finished then return reject("profile " .. profileState.name .. " is still running (profile-stop first)") end
  local path = WAVE_COMMAND_PATH:gsub("director%.cmd$", "waves/" .. name .. ".json")
  local fh, ferr = io.open(path, "r")
  if not fh then return reject("cannot open " .. path .. " (" .. tostring(ferr) .. ")") end
  local text = fh:read("*a"); fh:close()
  local okJ, doc = pcall(JsonDecode, text)
  if not okJ then return reject(tostring(doc)) end
  if type(doc) ~= "table" or doc.formatVersion ~= 1 then return reject("formatVersion must be 1") end
  if type(doc.waves) ~= "table" or #doc.waves < 1 or #doc.waves > 50 then return reject("waves must list 1 to 50 entries") end
  local brk = doc.breakSeconds == nil and 10 or doc.breakSeconds
  if type(brk) ~= "number" or brk < 0 or brk > 120 then return reject("breakSeconds must be 0 to 120") end
  for k in pairs(doc) do
    if k ~= "formatVersion" and k ~= "name" and k ~= "breakSeconds" and k ~= "waves" then return reject("unsupported field " .. tostring(k)) end
  end
  local plan, grand = {}, 0
  for i, w in ipairs(doc.waves) do
    if type(w) ~= "table" then return reject("wave " .. i .. " is not an object") end
    for k in pairs(w) do if k ~= "steps" then return reject("wave " .. i .. " has unsupported field " .. tostring(k)) end end
    local err, total, latest = ValidateSteps(w.steps, "wave " .. i)
    if err then return reject(err) end
    plan[i] = { steps = w.steps, total = total, latest = latest }; grand = grand + total
  end
  profileState = { name = name, idx = 0, finished = false, stopped = false, brk = brk, requested = grand }
  local state = profileState
  local function startNext()
    if state.stopped then print("[Reforged] profile stopped name=" .. name .. " after wave " .. state.idx); state.finished = true; return end
    state.idx = state.idx + 1
    if state.idx > #plan then
      print(string.format("[Reforged] profile end name=%s waves=%d requested_total=%d", name, #plan, grand)); state.finished = true; return
    end
    local w = plan[state.idx]
    WaveBegin(string.format("profile %s wave %d", name, state.idx), w.latest + 8)
    waveTrack.onEnd = function() After(state.brk * 1000, startNext) end
    for _, st in ipairs(w.steps) do
      local row, door, count = PROTO_BY_NAME[st.proto], st.door, st.count
      After(st.atSeconds * 1000, function() StepSpawn(door, row, count) end)
    end
    print(string.format("[Reforged] profile wave start name=%s wave=%d of %d requested=%d", name, state.idx, #plan, w.total))
  end
  print(string.format("[Reforged] profile scheduled name=%s waves=%d requested_total=%d breakSeconds=%d", name, #plan, grand, brk))
  startNext()
end
ProfileStop = function()
  if profileState and not profileState.finished then profileState.stopped = true; print("[Reforged] profile-stop requested; the current wave finishes, no further wave starts")
  else print("[Reforged] profile-stop: no profile running") end
end

-- Settings file: settings.json in the runtime folder, next to endless-mode.txt. It is read at each match start
-- (both auto-test map-ready places) and by `settings-reload`. The rows follow the options settings draft
-- (approved 2026-10-18). The mode is not a row: endless-mode.txt selects it. A write to a game object waits for LevelPlayable.
-- One local (S) holds the helpers, so the main chunk stays under the 200-local limit.
do
  local S = {}
  S.gen = 0
  S.MO = { manual = true, reforged = true }
  S.OMD = { reforged = true }
  S.CL = { classic = true }
  S.OC = { reforged = true, classic = true }
  S.onoff = { on = true, off = true }
  S.wavesource = { generator = true, stock = true }
  S.stockoff = { stock = true, off = true }
  S.stockalt = { stock = true, alternate = true }
  S.breakmode = { wait = true, auto = true, timed = true }
  S.counteddoor = { counted = true, door = true }
  function S.Id(x) return x end
  function S.IsOn(x) return x == "on" end

  function S.Show(v)
    if type(v) == "table" then return "table" end
    return tostring(v)
  end

  function S.ReadFile(path)
    local fh = io.open(path, "r")
    if not fh then return nil end
    local text = fh:read("*a") or ""
    fh:close()
    return text
  end

  -- Returns ok, value. No clamping: an out-of-range value is not ok.
  function S.Check(row, v)
    if row.type == "bool" then return type(v) == "boolean", v end
    if row.type == "enum" then return type(v) == "string" and row.values[v] == true, v end
    if row.extra ~= nil and v == row.extra then return true, v end
    if type(v) ~= "number" then return false, v end
    if row.type == "int" and v ~= math.floor(v) then return false, v end
    return v >= row.min and v <= row.max, v
  end

  SettingsCheck = S.Check

  function S.Default(row, mode)
    if mode == "manual" and row.dflt_manual ~= nil then return row.dflt_manual end
    return row.dflt
  end

  -- Runs fn on the game thread once LevelPlayable reports true. A new settings load cancels the wait.
  -- It gives up after 300 s, with one line.
  function S.WhenPlayable(label, fn)
    local gen, tries, done = S.gen, 0, false
    GameLoop(2000, function()
      if done or gen ~= S.gen then return true end
      tries = tries + 1
      if tries > 150 then
        print("[Reforged] settings: " .. label .. " not applied, level not playable after 300 s")
        return true
      end
      do
        local function gtBody()
          if done or gen ~= S.gen then return end
          if not LevelPlayable() then return end
          done = true
          local ok, err = pcall(fn)
          if not ok then print("[Reforged] settings: " .. label .. " failed: " .. tostring(err)) end
        end
        gtBody()
      end
      return false
    end)
  end

  -- A curve row. Sets one value in CURVE_WANT, then applies all curves once the level is playable.
  function S.CurveRow(name, kind)
    return function(v, row)
      if kind == "cap" then CURVE_WANT[name].cap = (v ~= "none") and v or nil
      else CURVE_WANT[name].scale = v end
      S.WhenPlayable(row.key, function() CurveApplyAll() end)
    end
  end

  -- A Difficulty Manager field. The stock value (the default) is written as "stock", so DmSet restores the game's own value.
  function S.DmApply(field)
    return function(v, row)
      S.WhenPlayable(row.key, function()
        if v == row.dflt then DmSet(field, "stock") else DmSet(field, v) end
      end)
    end
  end

  -- An ai-perf field (AiPerfSet). toValue turns the file value into the field value.
  function S.AiApply(name, toValue)
    return function(v, row)
      S.WhenPlayable(row.key, function() AiPerfSet(name, toValue(v)) end)
    end
  end

  SETTINGS_SPEC = {
    -- Player settings (P2 to P11). Every row without an apply function reports no-code-path, or not-this-mode.
    { key = "activeEnemyBudget", group = "player", type = "int", min = 20, max = 500, extra = "off", dflt = 120, dflt_manual = "off", apply = function(v)
        -- Reforged: the cap ceiling for the round plans (off = no ceiling). Manual: the spawn cap, as before.
        if SETTINGS_LAST and SETTINGS_LAST.mode == "reforged" then
          if v == "off" then REFORGED_BUDGET = nil else REFORGED_BUDGET = v end
          return
        end
        if v == "off" then SPAWN_CAP = nil else SPAWN_CAP = v end
      end },
    { key = "spawnSpacingSeconds", group = "player", type = "int", min = 10, max = 60, dflt = 10, apply = function(v) SPAWN_GAP = v end },
    { key = "waveSizeScale", group = "player", type = "float", min = 0.25, max = 4.0, dflt = 1.0, modes = S.OMD, apply = function(v) REFORGED_SIZE_SCALE = v end },
    { key = "waveSource", group = "player", type = "enum", values = S.wavesource, dflt = "generator", modes = S.OMD, apply = function(v) REFORGED_STOCK.source = v end },
    { key = "promotePercent", group = "player", type = "int", min = 0, max = 100, extra = "auto", dflt = "auto", modes = S.OMD, apply = function(v)
        if v == "auto" then REFORGED_PROMOTE_FIXED = nil else REFORGED_PROMOTE_FIXED = v end
      end },
    { key = "capStart", group = "developer", type = "int", min = 1, max = 500, dflt = 20, modes = S.OMD, apply = function(v) REFORGED_WAVES.capStart = v end },
    { key = "capGrowthPercent", group = "player", type = "float", min = 0, max = 100, dflt = 2, modes = S.OMD, apply = function(v) REFORGED_WAVES.capGrowthPercent = v end },
    { key = "waveModifiers", group = "player", type = "enum", values = S.onoff, dflt = "on", modes = S.OMD, apply = function(v) REFORGED_MOD.on = (v == "on") end },
    { key = "modifierChance", group = "player", type = "int", min = 0, max = 100, dflt = 20, modes = S.OC, apply = function(v) REFORGED_MOD.chance = v end },
    { key = "modifierMinRound", group = "developer", type = "int", min = 1, max = 100, dflt = 3, modes = S.OC, apply = function(v) REFORGED_MOD.minRound = v end },
    { key = "modifierBanner", group = "developer", type = "enum", values = S.onoff, dflt = "on", modes = S.OC, apply = function(v) HUD_BANNER.on = (v == "on") end },
    { key = "modifiersInClassic", group = "player", type = "enum", values = S.onoff, dflt = "off", modes = S.CL, apply = function(v) REFORGED_MOD.classic = v end },
    { key = "healthScale", group = "player", type = "float", min = 0.25, max = 4.0, dflt = 1.0, apply = S.DmApply("EndlessHealthModifier") },
    { key = "damageScale", group = "player", type = "float", min = 0.25, max = 4.0, dflt = 1.0, apply = S.DmApply("EndlessDamageModifier") },
    { key = "speedScale", group = "player", type = "float", min = 0.25, max = 4.0, dflt = 1.0, apply = S.DmApply("EndlessMovementSpeedModifier") },
    -- Reforged scaling curves. Defaults are stock: scale 1, no cap. Applied in Reforged only. Classic and Manual restore stock.
    { key = "curveHealth", group = "developer", type = "float", min = 0, max = 3, dflt = 1.0, modes = S.OMD, apply = S.CurveRow("health", "scale") },
    { key = "curveDamage", group = "developer", type = "float", min = 0, max = 3, dflt = 1.0, modes = S.OMD, apply = S.CurveRow("damage", "scale") },
    { key = "curveSpeed", group = "developer", type = "float", min = 0, max = 3, dflt = 1.0, modes = S.OMD, apply = S.CurveRow("speed", "scale") },
    { key = "curveCC", group = "developer", type = "float", min = 0, max = 3, dflt = 1.0, modes = S.OMD, apply = S.CurveRow("cc", "scale") },
    { key = "curveHealthCap", group = "developer", type = "float", min = 1, max = 1000, extra = "none", dflt = "none", modes = S.OMD, apply = S.CurveRow("health", "cap") },
    { key = "curveDamageCap", group = "developer", type = "float", min = 1, max = 1000, extra = "none", dflt = "none", modes = S.OMD, apply = S.CurveRow("damage", "cap") },
    { key = "curveSpeedCap", group = "developer", type = "float", min = 1, max = 1000, extra = "none", dflt = "none", modes = S.OMD, apply = S.CurveRow("speed", "cap") },
    { key = "goBreaks", group = "player", type = "enum", values = S.stockoff, dflt = "stock", apply = function(v, row)
        S.WhenPlayable(row.key, function()
          if v == "off" then BreaksOff() else DmSet("EndlessIterationNoGoBreaks", "stock") end
        end)
      end },
    { key = "breakMode", group = "player", type = "enum", values = S.breakmode, dflt = "wait", modes = S.OMD, apply = function(v) REFORGED_BREAK.mode = v end },
    { key = "breakSeconds", group = "player", type = "int", min = 5, max = 300, dflt = 30, modes = S.OMD, apply = function(v) REFORGED_BREAK.seconds = v end },
    { key = "preview", group = "player", type = "enum", values = S.onoff, dflt = "on", modes = S.OMD, apply = function(v) REFORGED_PREVIEW = (v == "on") end },
    { key = "aiPawnCollide", group = "player", type = "enum", values = S.onoff, dflt = "on", apply = function(v, row)
        S.WhenPlayable(row.key, function()
          PAWN_COLLIDE_OFF = v == "off"
          if not PAWN_COLLIDE_OFF then PawnCollideRestore() end
        end)
      end },
    { key = "routeSpread", group = "player", type = "enum", values = S.stockalt, dflt = "stock" },
    -- Reforged rules. Reforged only. Defaults are the approved values.
    -- roundCoinBase and roundCoinStep are file-only: the defaults stay in REFORGED_RULES when the file has no key.
    { key = "riftBossCost", group = "developer", type = "int", min = 1, max = 20, dflt = 10, modes = S.OMD, apply = function(v) REFORGED_RULES.riftBossCost = v end },
    { key = "riftRegenPerRound", group = "developer", type = "int", min = 0, max = 5, dflt = 0, modes = S.OMD, apply = function(v) REFORGED_RULES.riftRegenPerRound = v end },
    { key = "coinReduction", group = "developer", type = "enum", values = { stock = true, floor50 = true, off = true }, dflt = "floor50", modes = S.OMD, apply = function(v, row)
        REFORGED_RULES.coinReduction = v
        S.WhenPlayable(row.key, function() ReforgedCoinWrite(v) end)
      end },
    { key = "roundCoins", group = "developer", type = "enum", values = S.onoff, dflt = "on", modes = S.OMD, apply = function(v) REFORGED_RULES.roundCoins = v end },
    { key = "roundCoinBase", group = "developer", type = "int", min = 0, max = 100000, dflt = 300, fileOnly = true, modes = S.OMD, apply = function(v) REFORGED_RULES.roundCoinBase = v end },
    { key = "roundCoinStep", group = "developer", type = "int", min = 0, max = 10000, dflt = 20, fileOnly = true, modes = S.OMD, apply = function(v) REFORGED_RULES.roundCoinStep = v end },
    -- Developer settings (D1 to D17). The file is the only place for these (approved 2026-10-18).
    -- fileOnly: applied only when settings.json holds the key (source=file). A missing file must not cancel a testing command.
    { key = "testing", group = "developer", type = "enum", values = S.onoff, dflt = "off", fileOnly = true, apply = function(v, row)
        S.WhenPlayable(row.key, function()
          local want = v == "on"
          if TESTING ~= want then SetTesting(want) end
        end)
      end },
    { key = "watch", group = "developer", type = "enum", values = S.onoff, dflt = "on", apply = function(v) WATCH_ON = v == "on" end },
    { key = "watchTrackMs", group = "developer", type = "int", min = 500, max = 60000, extra = "off", dflt = 2000,
      apply = function(v) WATCH_TRACK_MS = v == "off" and 0 or v end },
    { key = "perf", group = "developer", type = "enum", values = S.onoff, dflt = "off", apply = function(v)
        PERF.on = v == "on"
        if PERF.on then PERF.lastWave = nil; PERF.lastReal = nil; PERF.lastFrames = nil; PERF.lastPawns = {} end
      end },
    { key = "hookTrace", group = "developer", type = "enum", values = S.onoff, dflt = "off", apply = function(v) HOOK_TRACE_ON = v == "on" end },
    { key = "startScreen", group = "developer", type = "enum", values = S.onoff, dflt = "on", modes = {} }, -- read at boot; no match-start apply
    { key = "hoardGate", group = "developer", type = "enum", values = S.onoff, dflt = "on", apply = function(v) HOARD_GATE = v == "on" end },
    { key = "directorSpawn", group = "developer", type = "enum", values = S.counteddoor, dflt = "counted" },
    { key = "anchorAutoRelease", group = "developer", type = "enum", values = S.onoff, dflt = "on", apply = function(v, row)
        S.WhenPlayable(row.key, function()
          ANCHOR_AUTO = v == "on"
          if ANCHOR_AUTO then AnchorAutoStart() else ANCHOR_AUTO_GEN = ANCHOR_AUTO_GEN + 1 end
        end)
      end },
    { key = "anchorQuietSeconds", group = "developer", type = "int", min = 3, max = 30, dflt = 8 },
    { key = "placementRequireOpen", group = "developer", type = "enum", values = S.onoff, dflt = "on", apply = function(v) PLACEMENT_REQUIRE_OPEN = v == "on" end },
    { key = "allowFlyerDoorsForGround", group = "developer", type = "bool", dflt = false },
    { key = "nativeMaxAICharacters", group = "developer", type = "int", min = 1, max = 10000, dflt = 10000, apply = S.AiApply("maxai", S.Id) },
    { key = "aiOverlapPerfMode", group = "developer", type = "enum", values = S.onoff, dflt = "off", apply = S.AiApply("overlap", S.IsOn) },
    { key = "aiMovementSkipFrames", group = "developer", type = "int", min = 0, max = 16, dflt = 0, apply = S.AiApply("skipframes", S.Id) },
    { key = "aiTargeting", group = "developer", type = "enum", values = S.onoff, dflt = "on", apply = S.AiApply("targeting", S.IsOn) },
    { key = "aiMovementUpdateGroups", group = "developer", type = "int", min = 0, max = 8, dflt = 0 },
    -- Read by the menu font block when a screen opens. No match-start apply.
    { key = "menuFont", group = "developer", type = "enum", values = { bangers = true, stock = true }, dflt = "bangers", modes = {} },
  }
  S.known = {}
  for _, row in ipairs(SETTINGS_SPEC) do
    row.modes = row.modes or S.MO
    S.known[row.key] = row
  end

  -- Reads settings.json once. Returns { mode, values, sources, invalid }. Prints the file-level and per-key lines.
  function LoadSettings(mode)
    local res = { mode = mode, values = {}, sources = {}, invalid = {} }
    local doc = nil
    local path = WAVE_COMMAND_PATH and (WAVE_COMMAND_PATH:gsub("director%.cmd$", "settings.json"))
    local text = path and S.ReadFile(path)
    if not text then
      print("[Reforged] settings file missing, defaults used")
    else
      local okJ, parsed = pcall(JsonDecode, text)
      if not okJ then
        print("[Reforged] settings file not read, defaults used: " .. tostring(parsed))
      elseif type(parsed) ~= "table" then
        print("[Reforged] settings file is not a JSON object, defaults used")
      else
        local fv = parsed.formatVersion
        if fv == nil then
          print("[Reforged] settings formatVersion missing, defaults used")
        elseif fv == 1 then
          doc = parsed
        elseif type(fv) == "number" and fv > 1 and fv == math.floor(fv) then
          print(string.format("[Reforged] settings formatVersion %d is newer than 1, defaults used", fv))
        else
          print("[Reforged] settings formatVersion " .. S.Show(fv) .. " is not 1, defaults used")
        end
      end
    end
    for _, row in ipairs(SETTINGS_SPEC) do
      local raw = doc and doc[row.key]
      if raw == nil then
        res.values[row.key] = S.Default(row, mode)
        res.sources[row.key] = "default"
      else
        local ok, v = S.Check(row, raw)
        if ok then
          res.values[row.key] = v
          res.sources[row.key] = "file"
        else
          local d = S.Default(row, mode)
          res.values[row.key] = d
          res.sources[row.key] = "default"
          res.invalid[row.key] = S.Show(raw)
          print(string.format("[Reforged] setting %s invalid (%s), default %s", row.key, S.Show(raw), S.Show(d)))
        end
      end
    end
    if doc then
      local unknown = {}
      for k in pairs(doc) do
        if S.known[k] == nil and k ~= "formatVersion" and k ~= "mode" then unknown[#unknown + 1] = tostring(k) end
      end
      table.sort(unknown)
      for _, k in ipairs(unknown) do print("[Reforged] setting " .. k .. " unknown, ignored") end
      if doc.mode ~= nil then print("[Reforged] setting mode ignored: endless-mode.txt selects the mode") end
    end
    SETTINGS_LAST = res
    return res
  end

  -- Match start and settings-reload. Classic applies nothing. Otherwise each row prints one line and applies if it can.
  function ApplySettingsForMode(mode)
    S.gen = S.gen + 1
    local res = LoadSettings(mode)
    if mode == "classic" then
      print("[Reforged] settings: classic, not applied")
      local okStock, errStock = pcall(ClassicStockRestore)
      if not okStock then print("[Reforged] classic stock restore err=" .. tostring(errStock)) end
      -- Only the rows that declare classic mode apply (modifiersInClassic, modifierChance, modifierMinRound;). Other rows stay off in Classic.
      for _, row in ipairs(SETTINGS_SPEC) do
        if row.modes.classic and row.apply ~= nil then
          local okC, errC = pcall(row.apply, res.values[row.key], row)
          print(string.format("[Reforged] setting %s=%s source=%s applied=%s", row.key, S.Show(res.values[row.key]),
            res.sources[row.key], okC and "classic" or ("failed: " .. tostring(errC))))
        end
      end
    else
      for _, row in ipairs(SETTINGS_SPEC) do
        local applied = "yes"
        if not row.modes[mode] then applied = "not-this-mode"
        elseif row.apply == nil then applied = "no-code-path"
        elseif row.fileOnly and res.sources[row.key] ~= "file" then applied = "not-in-file" end
        print(string.format("[Reforged] setting %s=%s source=%s applied=%s", row.key, S.Show(res.values[row.key]), res.sources[row.key], applied))
        if applied == "yes" then
          local ok, err = pcall(row.apply, res.values[row.key], row)
          if not ok then print("[Reforged] setting " .. row.key .. " apply failed: " .. tostring(err)) end
        end
      end
    end
    -- Not Reforged: a curve the mod changed goes back to stock once the level is playable.
    if mode ~= "reforged" then S.WhenPlayable("curve-stock", function() CurveRestoreIfChanged() end) end
    pcall(WatchEmit, "settings", { mode = mode, values = res.values, invalid = res.invalid })
  end

  function SettingsReload()
    ApplySettingsForMode(ReadEndlessMode())
  end
end

-- BEGIN OPTIONS PAGE..
do
  -- One local (O) holds the helpers, so the main chunk stays under the 200-local limit.
  local O = {}
  O.scale = { 0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0, 4.0 }
  O.sliders = { "LookSensitivityXRow", "LookSensitivityYRow", "TargetingSensitivityRow", "FieldOfViewwRow" }
  OPTIONS_PENDING = false
  OPTIONS_POPULATING = false
  OPTIONS_PAGE_NAME = nil
  for _, v in ipairs({ "options-open", "options-set" }) do DEV_OPS[v] = true end

  -- The 12 rows of the Reforged page, in display order. Row i uses stock combo position i (InvertView first,
  -- PressToContinue last). Every row has a key. Each key is a player setting in settings.json.
  OPTIONS_ROWS = {
    { combo = "InvertView", label = "TextBlock_3", widget = "VerticalCameraInversion", omd = "Spawn gap (s)", key = "spawnSpacingSeconds", kind = "int", opts = { 10, 15, 20, 30, 45, 60 } },
    { combo = "InvertViewHorizontally", label = "TextBlock_15", widget = "HorizontalCameraInversion_1", omd = "Wave size x", key = "waveSizeScale", kind = "float", opts = O.scale },
    { combo = "Rumble", label = "VibrationEnabledText", widget = "RumbleRow", omd = "Health x", key = "healthScale", kind = "float", opts = O.scale },
    { combo = "HoldToSprint", label = "TextBlock_14", widget = "HoldToSprintRow", omd = "Damage x", key = "damageScale", kind = "float", opts = O.scale },
    { combo = "CameraOffset", label = "TextBlock_5", widget = "CameraOffsetRow", omd = "Speed x", key = "speedScale", kind = "float", opts = O.scale },
    { combo = "GoreVisibility", label = "TextBlock_11", widget = "GoreVisibilityRow", omd = "Go Breaks", key = "goBreaks", opts = { "stock", "off" } },
    { combo = "LoadoutStyle", label = "TextBlock_4", widget = "LoadoutStyleRow", omd = "Wave modifiers", key = "waveModifiers", opts = { "on", "off" } },
    { combo = "ShowTrapGrid", label = "TextBlock_6", widget = "ShowTrapGridRow", omd = "Modifier chance %", key = "modifierChance", kind = "int", opts = { 0, 10, 20, 35, 50, 100 } },
    { combo = "TrinketWeaponSwitch", label = "TextBlock_8", widget = "TrinketWeaponSwitchRow", omd = "Next-wave preview", key = "preview", opts = { "on", "off" } },
    { combo = "ShowParTime", label = "TextBlock_9", widget = "ShowParTimeRow", omd = "Cap growth % per round", key = "capGrowthPercent", kind = "float", opts = { 0, 1, 2, 3, 5 } },
    { combo = "ShowNearbyHealthBars", label = "TextBlock_12", widget = "ShowNearbyHealthBarsRow", omd = "Use Modifiers with Classic", key = "modifiersInClassic", opts = { "off", "on" } },
    { combo = "PressToContinue", label = "TextBlock_10", widget = "PressToContinueRow", omd = "Wave source", key = "waveSource", opts = { "generator", "stock" } },
  }

  -- Runs one game call. A failure prints one line and returns false.
  function O.try(step, fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then print("[Reforged] options " .. step .. " failed: " .. tostring(err)) end
    return ok
  end

  -- True when obj is a valid UE object. A nil or an error gives false.
  function O.valid(obj)
    if obj == nil then return false end
    local ok, v = pcall(function() return obj:IsValid() end)
    return ok and v == true
  end

  -- The valid instances of a class, in FindAllOf order.
  function O.found(className)
    local out = {}
    local okF, list = pcall(FindAllOf, className)
    if okF and list then
      for _, o in ipairs(list) do
        if O.valid(o) then out[#out + 1] = o end
      end
    end
    return out
  end

  -- The page path name: the full name without the class prefix (the text after the first space).
  function O.pagePath(full)
    return tostring(full):match("^%S+%s+(.*)$") or tostring(full)
  end

  -- The row of the Reforged page with this key, or nil. Keys are unique.
  function O.rowByKey(key)
    if key == nil then return nil end
    for _, row in ipairs(OPTIONS_ROWS) do
      if row.key == key then return row end
    end
    return nil
  end

  -- True when the row is one of the rows of the Reforged page.
  function O.onPage(row)
    for _, r in ipairs(OPTIONS_ROWS) do
      if r == row then return true end
    end
    return false
  end

  -- The row that uses this stock combo name, or nil.
  function O.rowByCombo(name)
    for _, row in ipairs(OPTIONS_ROWS) do
      if row.combo == name then return row end
    end
    return nil
  end

  function O.setting(key)
    for _, row in ipairs(SETTINGS_SPEC) do
      if row.key == key then return row end
    end
    return nil
  end

  -- The open Reforged page (the instance named by OPTIONS_PAGE_NAME), or nil.
  function O.page()
    if OPTIONS_PAGE_NAME == nil then return nil end
    for _, p in ipairs(O.found("UBP_GameplayOptions_C")) do
      local okN, full = pcall(function() return p:GetFullName() end)
      if okN and full == OPTIONS_PAGE_NAME then return p end
    end
    return nil
  end

  -- A number as display text. An int row gives an integer. A float row gives the shortest text that reads back to the
  -- same number, with at least one decimal place (1.0, 0.25).
  function O.num(v, kind)
    if kind == "int" and v == math.floor(v) then return string.format("%d", v) end
    for p = 1, 17 do
      local s = string.format("%." .. p .. "g", v)
      if tonumber(s) == v then
        if not s:find("[%.eE]") then s = s .. ".0" end
        return s
      end
    end
    return tostring(v)
  end

  -- Display text of a stored value. A number uses the row kind. Text gets an initial capital. reforged shows as Reforged.
  function OptionsDisplay(key, value)
    local row = O.rowByKey(key)
    if type(value) == "number" then return O.num(value, row and row.kind) end
    local s = tostring(value)
    if s == "reforged" then return "Reforged" end
    return s:sub(1, 1):upper() .. s:sub(2)
  end

  -- The stored value for a display text of a row option, or nil.
  function OptionsStored(key, display)
    local row = O.rowByKey(key)
    if row == nil then return nil end
    for _, v in ipairs(row.opts) do
      if OptionsDisplay(key, v) == display then return v end
    end
    return nil
  end

  -- Saves one player setting to settings.json (design 3.4). Keeps every other key. Returns true when saved.
  function WriteSettings(key, value)
    local row = O.setting(key)
    if row == nil or row.group ~= "player" then
      print("[Reforged] setting save rejected " .. tostring(key) .. ": not a player setting")
      return false
    end
    local okC = SettingsCheck(row, value)
    if not okC then
      print("[Reforged] setting save rejected " .. tostring(key) .. "=" .. tostring(value) .. ": invalid")
      return false
    end
    local path = WAVE_COMMAND_PATH and (WAVE_COMMAND_PATH:gsub("director%.cmd$", "settings.json"))
    if not path then
      print("[Reforged] setting save failed " .. key .. ": path not resolved")
      return false
    end
    local doc = {}
    local fh = io.open(path, "r")
    if fh then
      local text = fh:read("*a") or ""
      fh:close()
      local okJ, parsed = pcall(JsonDecode, text)
      if okJ and type(parsed) == "table" then
        doc = parsed
      else
        local bad = path .. ".bad"
        os.remove(bad)
        local moved, merr = os.rename(path, bad)
        if not moved then
          print("[Reforged] settings file not parsed, move to settings.json.bad failed: " .. tostring(merr))
          return false
        end
        print("[Reforged] settings file not parsed, moved to settings.json.bad")
        doc = {}
      end
    end
    doc.formatVersion = 1
    doc[key] = value
    local tmp = path .. ".tmp"
    local okW, werr = pcall(function()
      local out, err = io.open(tmp, "w")
      if not out then error(err) end
      out:write(WatchJson(doc) .. "\n")
      out:close()
    end)
    if not okW then
      print("[Reforged] setting save failed " .. key .. ": " .. tostring(werr))
      return false
    end
    os.remove(path)
    local renamed, rerr = os.rename(tmp, path)
    if not renamed then
      print("[Reforged] setting save failed " .. key .. ": " .. tostring(rerr))
      return false
    end
    print("[Reforged] setting saved " .. key .. "=" .. tostring(value))
    return true
  end

  -- The saved on/off value of a player setting. The file value when it is "on" or "off", else the row default.
  -- Reads the file only. It prints nothing and does not change SETTINGS_LAST.
  function ModifierSettingRead(key)
    local row = O.setting(key)
    local dflt = (row and row.dflt) or "off"
    local path = WAVE_COMMAND_PATH and (WAVE_COMMAND_PATH:gsub("director%.cmd$", "settings.json"))
    local fh = path and io.open(path, "r")
    if not fh then return dflt end
    local text = fh:read("*a") or ""
    fh:close()
    local okJ, parsed = pcall(JsonDecode, text)
    if okJ and type(parsed) == "table" and (parsed[key] == "on" or parsed[key] == "off") then return parsed[key] end
    return dflt
  end

  -- A widget of a page: the Blueprint variable first, then the widget tree by its path name. Nil when neither is valid.
  function OptionsWidget(page, name)
    if page == nil then return nil end
    local ok, w = pcall(function() return page[name] end)
    if ok and O.valid(w) then return w end
    local okS, s = pcall(function()
      return StaticFindObject(O.pagePath(page:GetFullName()) .. ".WidgetTree." .. name)
    end)
    if okS and O.valid(s) then return s end
    return nil
  end

  -- Fills the Reforged page (design 3.2 step 3). Each step runs on its own, so one failure does not stop the rest.
  function O.populate(page)
    OPTIONS_PAGE_NAME = page:GetFullName()
    local hide = { "Accept_BTN", "Reset_BTN" }
    for _, name in ipairs(O.sliders) do hide[#hide + 1] = name end
    for _, name in ipairs(hide) do
      O.try("collapse " .. name, function() OptionsWidget(page, name):SetVisibility(1) end)
    end
    O.try("cancel text", function() OptionsWidget(page, "CancelText"):SetText(FText("Done")) end)
    O.try("title", function() OptionsWidget(page, "TextBlock_7"):SetText(FText("Reforged")) end)
    -- All 12 rows show. Each row has a key.
    for _, row in ipairs(OPTIONS_ROWS) do
      O.try("row visible " .. row.combo, function() OptionsWidget(page, row.widget):SetVisibility(0) end)
    end

    local mode = ReadEndlessMode()
    local settings = nil
    O.try("load settings", function() settings = LoadSettings(mode) end)
    local values = {}
    for _, row in ipairs(OPTIONS_ROWS) do
      local value = nil
      if settings then value = settings.values[row.key] end
      values[row.key] = value
      O.try("row " .. row.key, function()
        if value == nil then error("no value") end
        local label = OptionsWidget(page, row.label)
        local combo = OptionsWidget(page, row.combo)
        local cur = OptionsDisplay(row.key, value)
        label:SetText(FText(row.omd))
        combo:ClearOptions()
        for _, v in ipairs(row.opts) do combo:AddOption(OptionsDisplay(row.key, v)) end
        if OptionsStored(row.key, cur) == nil then combo:AddOption(cur) end
        combo:SetSelectedOption(cur)
      end)
    end
    if MenuFontPage then pcall(MenuFontPage, page) end
    WatchEmit("ui", { screen = "reforged", action = "shown", values = values })
  end

  -- Runs once after the gameplay page Construct, when OPTIONS_PENDING was set. The newest page is the last valid one.
  function OptionsPopulate()
    local list = O.found("UBP_GameplayOptions_C")
    local page = list[#list]
    if page == nil then
      print("[Reforged] options populate skipped: no Reforged page")
      return
    end
    OPTIONS_POPULATING = true
    local ok, err = pcall(O.populate, page)
    OPTIONS_POPULATING = false
    if not ok then print("[Reforged] options populate failed: " .. tostring(err)) end
  end

  -- Opens the Reforged page over the stock Options menu (design 3.2 step 2). Closes the stock Editor commands first.
  function OptionsOpenPage()
    if not START_SCREEN then return end
    for _, ec in ipairs(O.found("UBP_EditorCommands_C")) do
      O.try("close editor commands", function() ec:Close() end)
    end
    local pc, cls, lib, task = nil, nil, nil, nil
    local okPc = O.try("find player controller", function()
      pc = FindFirstOf("OMDPlayerController")
      if not pc then error("OMDPlayerController not found") end
    end)
    local okCls = O.try("find options class", function()
      cls = StaticFindObject("/Game/UI/Options/UBP_GameplayOptions.UBP_GameplayOptions_C")
      if not O.valid(cls) then error("UBP_GameplayOptions_C not found") end
    end)
    local okLib = O.try("find modal library", function()
      lib = StaticFindObject("/Script/OMD.Default__OMDAsyncTaskShowModalWidget")
      if not O.valid(lib) then error("OMDAsyncTaskShowModalWidget default object not found") end
    end)
    if not (okPc and okCls and okLib) then
      OPTIONS_PENDING = false
      return
    end
    OPTIONS_PENDING = true
    local okShow = O.try("show modal", function()
      task = lib:ShowModalWidget(pc, cls)
      task:Activate()
    end)
    if not okShow then
      OPTIONS_PENDING = false
      return
    end
    WatchEmit("ui", { screen = "reforged", action = "open" })
  end

  -- Options menu Construct (design 3.2 step 1). Acts only on the start screen (the pause-menu rule).
  function OptionsMenuConstruct()
    if not START_SCREEN then return end
    -- Menu job, runs on any map (AfterAny).
    AfterAny(300, function()
      GameNow(function()
        if not START_SCREEN then return end
        if #O.found("MainMenu_UMG_C") == 0 then
          print("[Reforged] options page skipped: not the start screen")
          return
        end
        local menu = O.found("OptionsMenu_UMG_C")[1]
        if menu == nil then
          print("[Reforged] options menu not found")
          return
        end
        local okV = O.try("editor commands visible", function() OptionsWidget(menu, "EditorCommands"):SetVisibility(0) end)
        local okT = O.try("editor commands text", function() OptionsWidget(menu, "WithEditorText"):SetText(FText("Reforged")) end)
        if MenuFontScreen then pcall(MenuFontScreen, "options", { { OptionsWidget(menu, "WithEditorText"), "WithEditorText" } }) end
  if okV and okT then WatchEmit("ui", { screen = "options", action = "shown" }) end
      end)
    end)
  end

  -- The Reforged button click (design 3.2 step 2). The hook sets the pending flag, then opens the page on the game thread.
  function OptionsClickPressed()
    if not START_SCREEN then return end
    OPTIONS_PENDING = true
    GameNow(function() OptionsOpenPage() end)
  end

  -- Gameplay page Construct (design 3.2 step 3). Acts only after the Reforged button set the pending flag.
  function OptionsPageConstruct()
    if not START_SCREEN then return end
    if OPTIONS_PENDING ~= true then return end
    OPTIONS_PENDING = false
    -- Menu job, runs on any map (AfterAny).
    AfterAny(100, function()
      GameNow(function()
        local ok, err = pcall(OptionsPopulate)
        if not ok then print("[Reforged] options populate failed: " .. tostring(err)) end
      end)
    end)
  end

  -- A combo change (design 3.2 step 4). It reads the combo, the selection type and the selected text now, during the hook.
  -- The text comes from the hook's SelectedItem first, then from the inner ComboBox. It does not call
  -- c:GetSelectedOption(): the Blueprint wrapper needs one argument, and UE4SS passes none.
  function OptionsComboChanged(combo, selectedItem, selectType)
    if not START_SCREEN then return end
    local okR, c, full, sel = pcall(function()
      local obj = combo:get()
      return obj, obj:GetFullName(), selectType:get()
    end)
    if not okR then
      print("[Reforged] options change failed: " .. tostring(full))
      return
    end
    local okT, display = pcall(function() return selectedItem:get():ToString() end)
    if not okT then
      local okB, text = pcall(function() return c.ComboBox:GetSelectedOption():ToString() end)
      okT, display = okB, text
    end
    if not okT then
      print("[Reforged] options change failed: no selected text")
      return
    end
    local okC, errC = pcall(OptionsOnChange, full, display, sel)
    if not okC then print("[Reforged] options change failed: " .. tostring(errC)) end
  end

  -- Saves one Reforged change at once. It does nothing while the page is populated, or for another page instance.
  function OptionsOnChange(comboFullName, display, selectType)
    if not START_SCREEN then return end
    if OPTIONS_POPULATING then return end
    if OPTIONS_PAGE_NAME == nil then return end
    local full = tostring(comboFullName)
    if not full:find(O.pagePath(OPTIONS_PAGE_NAME) .. ".WidgetTree.", 1, true) then return end
    local combo = full:match("([^%.]+)$")
    local row = O.rowByCombo(combo)
    local stored = nil
    if row ~= nil then stored = OptionsStored(row.key, display) end
    if stored == nil then
      print("[Reforged] options change ignored: " .. tostring(combo) .. " " .. tostring(display))
      return
    end
    WatchEmit("ui", { screen = "reforged", action = "change", key = row.key, value = stored, select = selectType })
    local ok = WriteSettings(row.key, stored) == true
    WatchEmit("ui", { screen = "reforged", action = "saved", key = row.key, file = "settings.json", ok = ok })
  end

  -- Developer command `options-open`: opens the Reforged page with no click (design 4.2).
  -- It takes no word. Any word after it is rejected, and the page does not open.
  function OptionsCommandOpen(word)
    if not START_SCREEN then
      print("[Reforged] options-open rejected: start-screen is off")
      return
    end
    if word ~= nil then
      print("[Reforged] options-open rejected: use options-open")
      return
    end
    OptionsOpenPage()
    print("[Reforged] options-open sent")
  end

  -- Developer command `options-set <key> <value>`: selects an option of the open page (design 4.2).
  -- The stock combo then fires its own change event, so OptionsOnChange runs as for a mouse pick.
  function OptionsCommandSet(key, text)
    if not START_SCREEN then
      print("[Reforged] options-set rejected: start-screen is off")
      return
    end
    local row = O.rowByKey(key)
    if row == nil then
      print("[Reforged] options-set rejected: unknown key " .. tostring(key))
      return
    end
    local page = O.page()
    if page == nil then
      print("[Reforged] options-set rejected: the Reforged page is not open")
      return
    end
    if not O.onPage(row) then
      print("[Reforged] options-set rejected: " .. tostring(key) .. " is not on the open page")
      return
    end
    text = text or ""
    local display = OptionsDisplay(key, tonumber(text) or text)
    if OptionsStored(key, display) == nil then
      print("[Reforged] options-set rejected: " .. tostring(key) .. " " .. text .. " is not an option")
      return
    end
    local okSet = O.try("options-set", function() OptionsWidget(page, row.combo):SetSelectedOption(display) end)
    if okSet then print("[Reforged] options-set " .. key .. " " .. display) end
  end

  -- Registers the four hooks (design 3.2 steps 1 to 4), once at load, on the game thread.
  ExecuteInGameThread(function()
    local okL1, errL1 = pcall(LoadAsset, "/Game/UI/Options/OptionsMenu_UMG.OptionsMenu_UMG_C")
    print("[Reforged] options menu LoadAsset ok=" .. tostring(okL1) .. " " .. tostring(errL1))
    local ok1, e1 = SafeRegisterHook("/Game/UI/Options/OptionsMenu_UMG.OptionsMenu_UMG_C:Construct", function()
      OptionsMenuConstruct()
    end)
    print("[Reforged] options construct registered=" .. tostring(ok1) .. " " .. tostring(e1))
    local ok2, e2 = SafeRegisterHook("/Game/UI/Options/OptionsMenu_UMG.OptionsMenu_UMG_C:BndEvt__EditorCommands_K2Node_ComponentBoundEvent_34_OnButtonClickedEvent__DelegateSignature", function()
      OptionsClickPressed()
    end)
    print("[Reforged] options click registered=" .. tostring(ok2) .. " " .. tostring(e2))
    local okL2, errL2 = pcall(LoadAsset, "/Game/UI/Options/UBP_GameplayOptions.UBP_GameplayOptions_C")
    print("[Reforged] options gameplay LoadAsset ok=" .. tostring(okL2) .. " " .. tostring(errL2))
    local ok3, e3 = SafeRegisterHook("/Game/UI/Options/UBP_GameplayOptions.UBP_GameplayOptions_C:Construct", function()
      OptionsPageConstruct()
    end)
    print("[Reforged] options gameplay registered=" .. tostring(ok3) .. " " .. tostring(e3))
    local okL3, errL3 = pcall(LoadAsset, "/Game/UI/Options/UBP_OptionsComboBox.UBP_OptionsComboBox_C")
    print("[Reforged] options combo LoadAsset ok=" .. tostring(okL3) .. " " .. tostring(errL3))
    local ok4, e4 = SafeRegisterHook("/Game/UI/Options/UBP_OptionsComboBox.UBP_OptionsComboBox_C:BndEvt__ComboBox_K2Node_ComponentBoundEvent_0_OnSelectionChangedEvent__DelegateSignature", function(self, SelectedItem, SelectionType)
      OptionsComboChanged(self, SelectedItem, SelectionType)
    end)
    print("[Reforged] options combo registered=" .. tostring(ok4) .. " " .. tostring(e4))
  end)
end
-- END OPTIONS PAGE
-- BEGIN MENU FONT..
do
  -- One local (MF) holds the constants, the cached font and the helpers. The main chunk stays under the 200-local limit.
  local MF = { path = "/Game/UI/Fonts/Bangers_OMD_Basic_Font.Bangers_OMD_Basic_Font", face = "Bangers",
    itemClass = "/Game/UI/Options/UBP_ComboBoxTextOption.UBP_ComboBoxTextOption_C",
    comboClass = "/Game/UI/Options/UBP_OptionsComboBox.UBP_OptionsComboBox_C", pending = false,
    font = nil, seenFor = nil, calls = {} }
  DEV_OPS["menu-font"] = true

  -- True when obj is a valid UE object. A nil or an error gives false.
  function MF.valid(obj)
    if obj == nil then return false end
    local ok, v = pcall(function() return obj:IsValid() end)
    return ok and v == true
  end

  -- The Bangers font object. A valid object is cached. StaticFindObject first, then LoadAsset (game thread only).
  function MF.object()
    if MF.valid(MF.font) then return MF.font end
    local ok, o = pcall(StaticFindObject, MF.path)
    if not (ok and MF.valid(o)) then
      pcall(LoadAsset, MF.path)
      ok, o = pcall(StaticFindObject, MF.path)
    end
    if ok and MF.valid(o) then
      MF.font = o
      return o
    end
    return nil
  end

  -- The menuFont value in settings.json, or nil. Nil for no file, a read or parse error, formatVersion other than 1, or a bad value.
  function MF.fileValue()
    local path = WAVE_COMMAND_PATH and (WAVE_COMMAND_PATH:gsub("director%.cmd$", "settings.json"))
    if not path then return nil end
    local okR, text = pcall(function()
      local fh = io.open(path, "r")
      if not fh then return nil end
      local t = fh:read("*a") or ""
      fh:close()
      return t
    end)
    if not okR or type(text) ~= "string" then return nil end
    local okJ, doc = pcall(JsonDecode, text)
    if not okJ or type(doc) ~= "table" or doc.formatVersion ~= 1 then return nil end
    if doc.menuFont == "bangers" or doc.menuFont == "stock" then return doc.menuFont end
    return nil
  end

  -- "bangers" or "stock". The command value (MENU_FONT_OVERRIDE) wins, then the file, then bangers.
  function MenuFontMode()
    if MENU_FONT_OVERRIDE == "bangers" or MENU_FONT_OVERRIDE == "stock" then return MENU_FONT_OVERRIDE end
    return MF.fileValue() or "bangers"
  end

  -- Runs fn in its own pcall. Returns the value, or nil on an error.
  function MF.try(fn)
    local ok, v = pcall(fn)
    if ok then return v end
    return nil
  end

  -- The full name of a UE object, or nil. A plain value (no GetFullName) gives nil.
  function MF.name(obj)
    if obj == nil then return nil end
    local ok, v = pcall(function() return obj:GetFullName() end)
    if ok and type(v) == "string" then return v end
    return nil
  end

  -- Text of an FName (ToString) or of a plain value. Nil gives nil.
  function MF.text(v)
    if v == nil then return nil end
    local ok, s = pcall(function() return v:ToString() end)
    if ok and type(s) == "string" then return s end
    return tostring(v)
  end

  -- The title style of a widget as plain values: FontMaterial and the OutlineSettings fields. Each read has its own pcall.
  -- Returns a table. Its fields are nil when the game gives nil or an error.
  function MF.style(widget)
    local st = {}
    st.mat = MF.try(function() return widget.Font.FontMaterial end)
    st.outSize = MF.try(function() return widget.Font.OutlineSettings.OutlineSize end)
    st.outMat = MF.try(function() return widget.Font.OutlineSettings.OutlineMaterial end)
    st.outR = MF.try(function() return widget.Font.OutlineSettings.OutlineColor.R end)
    st.outG = MF.try(function() return widget.Font.OutlineSettings.OutlineColor.G end)
    st.outB = MF.try(function() return widget.Font.OutlineSettings.OutlineColor.B end)
    st.outA = MF.try(function() return widget.Font.OutlineSettings.OutlineColor.A end)
    st.sepAlpha = MF.try(function() return widget.Font.OutlineSettings.bSeparateFillAlpha end)
    st.dropShadow = MF.try(function() return widget.Font.OutlineSettings.bApplyOutlineToDropShadows end)
    if type(st.sepAlpha) ~= "boolean" then st.sepAlpha = nil end
    if type(st.dropShadow) ~= "boolean" then st.dropShadow = nil end
    return st
  end

  -- The OutlineSettings table for SetFont. Nil unless the size and all four colour values were read.
  function MF.outlineTable(st)
    if type(st.outSize) ~= "number" or type(st.outR) ~= "number" or type(st.outG) ~= "number"
      or type(st.outB) ~= "number" or type(st.outA) ~= "number" then
      return nil
    end
    return { OutlineSize = st.outSize, OutlineMaterial = st.outMat,
      OutlineColor = { R = st.outR, G = st.outG, B = st.outB, A = st.outA },
      bSeparateFillAlpha = st.sepAlpha, bApplyOutlineToDropShadows = st.dropShadow }
  end

  -- Sets Bangers on one text widget. Only the old values are read first, as plain values. The struct object is never written.
  -- The new struct is passed to SetFont with the old size, spacing and title style. A read-back decides ok, else the old values are restored.
  -- Returns true or false. In stock mode it returns nil and prints nothing. The reforged-item screen prints only the ok or err line.
  function MenuFontApply(widget, screen, name)
    if MenuFontMode() == "stock" then return nil end
    local quiet = screen == "reforged-item"
    local label = "[Reforged] menu-font " .. tostring(screen) .. " " .. tostring(name)
    if widget == nil then
      print(label .. " ok=false err=not found")
      return false
    end
    local obj = MF.object()
    if obj == nil then
      print(label .. " ok=false err=font object not found")
      return false
    end
    local oldObj = MF.try(function() return widget.Font.FontObject end)
    local oldFace = MF.try(function() return widget.Font.TypefaceFontName end)
    local oldSize = MF.try(function() return widget.Font.Size end)
    local oldSpacing = MF.try(function() return widget.Font.LetterSpacing end)
    local style = MF.style(widget)
    if not quiet then
      print(label .. " before size=" .. tostring(oldSize) .. " obj=" .. tostring(MF.name(oldObj))
        .. " face=" .. tostring(MF.text(oldFace))
        .. " mat=" .. tostring(MF.name(style.mat)) .. " outline=" .. tostring(style.outSize))
    end
    if type(oldSize) ~= "number" or oldSize <= 0 then
      print(label .. " ok=false err=size not readable")
      return false
    end
    pcall(function()
      widget:SetFont({ FontObject = obj, TypefaceFontName = FName(MF.face), Size = oldSize, LetterSpacing = oldSpacing or 0,
        FontMaterial = style.mat, OutlineSettings = MF.outlineTable(style) })
    end)
    local newSize = MF.try(function() return widget.Font.Size end)
    local newObj = MF.try(function() return widget.Font.FontObject end)
    local newName = MF.name(newObj)
    if not quiet then
      local newStyle = MF.style(widget)
      print(label .. " after size=" .. tostring(newSize) .. " obj=" .. tostring(newName)
        .. " mat=" .. tostring(MF.name(newStyle.mat)) .. " outline=" .. tostring(newStyle.outSize))
    end
    if newSize == oldSize and newName ~= nil and newName:find("Bangers_OMD_Basic_Font", 1, true) ~= nil then
      print(label .. " ok=true")
      return true
    end
    local okR = pcall(function()
      widget:SetFont({ FontObject = oldObj, TypefaceFontName = oldFace, Size = oldSize, LetterSpacing = oldSpacing or 0 })
    end)
    print(label .. " ok=false err=readback size=" .. tostring(newSize) .. " obj=" .. tostring(newName) .. " restored=" .. tostring(okR))
    return false
  end

  -- Applies Bangers to { widget, name } items of one screen. It emits one ui font event. Stock mode does nothing.
  function MenuFontScreen(screen, items)
    if MenuFontMode() == "stock" then return 0, 0 end
    local ok, fail = 0, 0
    for _, item in ipairs(items) do
      if MenuFontApply(item[1], screen, item[2]) == true then ok = ok + 1 else fail = fail + 1 end
    end
    WatchEmit("ui", { screen = "font", action = "applied", target = screen, ok = ok, fail = fail })
    return ok, fail
  end

  -- The Reforged page: the title, Done and the row labels. The combo items are hooked below.
  function MenuFontPage(page)
    if MenuFontMode() == "stock" then return end
    local names = { "TextBlock_7", "CancelText" }
    for _, row in ipairs(OPTIONS_ROWS) do names[#names + 1] = row.label end
    local items = {}
    for i, name in ipairs(names) do items[i] = { OptionsWidget(page, name), name } end
    MenuFontScreen("reforged", items)
  end

  -- Counts the calls of one kind (gen or item) on the open page. The count restarts when OPTIONS_PAGE_NAME changes.
  function MF.pageCall(key)
    if OPTIONS_PAGE_NAME ~= MF.seenFor then
      MF.seenFor = OPTIONS_PAGE_NAME
      MF.calls = {}
    end
    local n = (MF.calls[key] or 0) + 1
    MF.calls[key] = n
    return n
  end

  -- Pre-hook on UBP_OptionsComboBox GenerateWidget. self is the combo. MF.pending is set when the combo is under the
  -- open Reforged page (Bangers mode). The items that the combo creates next are then set in MF.onItem.
  function MF.onGen(self)
    local okC, combo = pcall(function() return self:get() end)
    local full = okC and MF.name(combo) or nil
    local short = full and (full:match("([^%.]+)$") or full) or "nil"
    local prefix = nil
    if OPTIONS_PAGE_NAME ~= nil then
      local pagePath = tostring(OPTIONS_PAGE_NAME):match("^%S+%s+(.*)$")
      if pagePath ~= nil then prefix = pagePath .. ".WidgetTree." end
    end
    local pageOk = MenuFontMode() == "bangers" and prefix ~= nil and full ~= nil and full:find(prefix, 1, true) ~= nil
    MF.pending = pageOk and true or false
    if MF.pageCall("gen") <= 3 then
      print("[Reforged] menu-font gen " .. short .. " page=" .. tostring(pageOk))
    end
  end

  -- Pre-hook on UBP_ComboBoxTextOption SetValue. self is the item. When MF.pending is set, Bangers goes on the item's
  -- OptionText. The flag is cleared on each call, so one GenerateWidget sets at most one item.
  function MF.onItem(self)
    local pending = MF.pending == true
    MF.pending = false
    local okI, item = pcall(function() return self:get() end)
    local full = okI and MF.name(item) or nil
    if MF.pageCall("item") <= 3 then
      print("[Reforged] menu-font item seen " .. tostring(full) .. " pending=" .. tostring(pending))
    end
    if not pending or not okI or not MF.valid(item) then return end
    local okT, text = pcall(function() return item.OptionText end)
    if not okT then text = nil end
    MenuFontApply(text, "reforged-item", full and (full:match("([^%.]+)$") or full) or "item")
  end

  -- Registers the two hooks once at load (game thread). Each is a single pre-callback, like the options block.
  ExecuteInGameThread(function()
    pcall(LoadAsset, MF.comboClass)
    local okG, errG = SafeRegisterHook(MF.comboClass .. ":GenerateWidget", function(self)
      pcall(MF.onGen, self)
    end)
    print("[Reforged] menu-font gen hook registered=" .. tostring(okG) .. " " .. tostring(errG))
    pcall(LoadAsset, MF.itemClass)
    local okH, errH = SafeRegisterHook(MF.itemClass .. ":SetValue", function(self)
      pcall(MF.onItem, self)
    end)
    print("[Reforged] menu-font item hook registered=" .. tostring(okH) .. " " .. tostring(errH))
  end)

  -- Developer command `menu-font bangers|stock`. It sets the run-time mode. Send `testing on` first.
  function MenuFontCommand(value)
    if value == "bangers" or value == "stock" then
      MENU_FONT_OVERRIDE = value
      print("[Reforged] menu-font=" .. value)
    else
      print("[Reforged] menu-font rejected: use menu-font bangers|stock")
    end
  end
end
-- END MENU FONT

-- Map leave. The second map load crashed in a Lua call (EXCEPTION_ACCESS_VIOLATION, 2026-10-19 16:21:31 local):
-- Unreal frees the old map's objects during the next load, but the 1 s steps still held the old actors until map ready.
-- The LoadMap pre-hook runs before that free. It empties every per-map table that holds an actor, sets REFORGED.ready to
-- false (no round and no gate block until MapReadyFor), opens the break gate, and adds 1 to MAP_EPOCH.
-- Globals only, inside do ... end, so the main chunk gets no new locals.
do
  function ReforgedMapLeave(why)
    MAP_EPOCH = (MAP_EPOCH or 0) + 1
    REFORGED.ready = false
    HOARD_HELD, PACE_QUEUE, DOOR_PENDING = {}, {}, {}
    REFORGED_BOSSES_LIVE, REFORGED_BEARERS, REFORGED_WISPS = {}, {}, {}
    REFORGED.wispRound, REFORGED.wispKinds, REFORGED.wispMode = nil, nil, nil
    REFORGED_RULES.mb, REFORGED_RULES.riftLocs = {}, nil
    REFORGED.mapBossPending = nil
    waveTrack.active, waveTrack.pawns = false, {}
    for i = #goblins, 1, -1 do goblins[i] = nil end
    CSPAWN_POINT_CACHE = {}
    RIFT_ROUTE.on, RIFT_ROUTE.endPoint = false, nil
    RIFT_RESPAWN.on, RIFT_RESPAWN.P, RIFT_RESPAWN.rift = false, nil, nil
    pcall(AnchorNewMap)
    TICK_HOLD, TICK_HOLD_AUTO_ON, TICK_HOLD_UNTIL = false, false, 0
    REFORGED_BREAK.brk = nil
    if BREAK_GATE.blocked == true then pcall(BreakGateSet, false, "map-leave") end
    pcall(WatchMapLeave)
    -- The next map runs MapReadyFor even when its coordinator gets the old address.
    MAP_READY.mapKey, MAP_READY.settingsKey, MAP_READY.lastPrintedKey = nil, nil, nil
    print(string.format("[Reforged] map-leave why=%s epoch=%d", tostring(why), MAP_EPOCH))
  end
  if type(RegisterLoadMapPreHook) == "function" then
    local okH, errH = pcall(RegisterLoadMapPreHook, function() pcall(ReforgedMapLeave, "load-map") end)
    MAP_LEAVE_HOOKED = okH == true
    print("[Reforged] map-leave load-map hook registered=" .. tostring(okH) .. (okH and "" or (" err=" .. tostring(errH))))
  else
    print("[Reforged] map-leave load-map hook not available; the no-coordinator fallback is used")
  end
end

-- Claim each one-shot command by rename so a partially written file is never
-- executed. The command helper writes into this same Win64 directory.
local COMMAND_PATH = ResolveDirectorCommandPath()
WAVE_COMMAND_PATH = COMMAND_PATH -- read by RunWaveFile, which is defined above this line
if COMMAND_PATH then
  print("[Reforged] director command path=" .. COMMAND_PATH)
else
  print("[Reforged] director command path unavailable from IterateGameDirectories")
end
local COMMAND_WORKING_PATH = COMMAND_PATH and (COMMAND_PATH .. ".working") or nil
local function PollDirectorCommand()
  if not COMMAND_PATH then return false end
  -- A stale .working file from a crash is removed, not run. Rename fails on Windows while it exists.
  local okR, removed = pcall(os.remove, COMMAND_WORKING_PATH)
  if okR and removed then print("[Reforged] director command: removed stale director.cmd.working (not run)") end
  local ok, claimed = pcall(os.rename, COMMAND_PATH, COMMAND_WORKING_PATH)
  if not ok or not claimed then return false end
  local file, err = io.open(COMMAND_WORKING_PATH, "r")
  if not file then
    print("[Reforged] director command read failed: " .. tostring(err))
    pcall(os.remove, COMMAND_WORKING_PATH)
    return false
  end
  local command = file:read("*l")
  file:close()
  pcall(os.remove, COMMAND_WORKING_PATH)
  if command and command:match("%S") then
    -- The command runs on any map (third argument true).
    RunOnGameThread("cmd", function() DispatchCommand(command) end, true)
  end
  return false
end
GameLoop(2000, PollDirectorCommand)

-- Hooks are registered once, here at load. Every crash today followed `testing on`. Cause inferred.
-- Each body returns early unless TESTING is on. The damage probe is not here: it starts with `dmg-probe on`.
HookRoundFeign()
ReforgedHookTimedBreak()
DIAG_STARTED = true
for _, fn in ipairs(DIAG) do pcall(fn) end

StartWaveMonitor()
print("[Reforged] wave director ready: command file supports spawn, random, mix, wave-amount, wave-class, spawn-at, probe, proto-check, inspect-protos, inspect-doors, status, placement-open, hoard-gate, hook-trace; testing=off (send `testing on` for the developer features)")
