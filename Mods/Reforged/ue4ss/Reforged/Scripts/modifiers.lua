-- Reforged wave modifiers. Pure module: no globals, no UE4SS calls.
-- A modifier is a transform on a round plan:
--   plan = { round, size, cap, promote, entries = { { proto, count, promote?, door?, rate?, bearer? }, ... }, reinforce? }
-- Apply returns a new plan. It never changes the input.
-- bearer (entry): main.lua keeps the pawn and sends reinforcement calls from its door while it stands.
-- reinforce (plan): { every, everyCrowd, count, limit, protos }. Seconds between calls, the call size, the call limit per bearer, and the proto cycle.
-- main.lua loads it for the plans.
-- Each record has title and line for the on-screen banner. M.Banner(id) returns them.

local M = {}

local MASK = 0xFFFFFFFF

-- Scramble a 32-bit value (lowbias32-style finalizer).
local function mix(x)
  x = x ~ (x >> 16)
  x = (x * 0x7feb352d) & MASK
  x = x ~ (x >> 15)
  x = (x * 0x846ca68b) & MASK
  x = x ~ (x >> 16)
  return x
end

-- Deterministic RNG. Each call returns a number in [0, 1). Same seed and round give the same sequence.
function M.Rng(seed, round)
  local s = mix(((math.tointeger(seed) or 0) * 2654435761 + (math.tointeger(round) or 0) * 40503 + 1) & MASK)
  if s == 0 then s = 0x6D2B79F5 end
  return function()
    s = s ~ ((s << 13) & MASK)
    s = s ~ (s >> 17)
    s = s ~ ((s << 5) & MASK)
    return s / 4294967296
  end
end

-- Pools. Each transform cycles through its pool by entry index.
local POOL = {
  horde = { "OrcLight", "OrcMedium", "Kobold" },
  iron = { "OrcHeavy", "OgreArmored", "TrollMountain", "LizardmanHeavy", "CyclopsHeavy" },
  sapper = { "KoboldTNT", "OrcArcherTNT" },
  fire = { "FireFiendLight", "FireFiendMedium", "FireFiendHeavy", "FireFiendRunner", "ElementalFireling", "ElementalFire" },
  mystic = { "CyclopsMage", "CyclopsShaman", "WraithHealer", "FireFiendMage" },
  herd = { "LootGoblin", "OgreMoneybags" },
  elite = { "OgreArmored", "TrollMountain", "CyclopsShaman", "CyclopsMesmerizer", "FireFiendMage", "LizardmanAssassin" },
  bearer = { "OgreArmored" },
  reinforce = { "OrcLight", "OrcMedium", "Kobold" },
}

-- Bosses never change in elite-guard.
local BOSS = { OrcBoss = true, KoboldKing = true, OgreBasher = true, WraithBoss = true }

-- Each non-boss entry has this chance to become an elite proto.
local ELITE_CHANCE = 0.15

local function cycle(pool, n)
  return pool[((n - 1) % #pool) + 1]
end

local function clone(v)
  if type(v) ~= "table" then return v end
  local out = {}
  for k, x in pairs(v) do out[k] = clone(x) end
  return out
end

-- n entries of count pawns. Entry i takes pool[i] (cycled). Used by the Classic forms.
local function squads(pool, n, count)
  local out = {}
  for i = 1, n do out[i] = { proto = cycle(pool, i), count = count } end
  return out
end

local REG = {
  {
    id = "horde", title = "HORDE RUSH", line = "Double squads, no promotions.", kind = "special", weight = 10, minRound = 3, additive = false, available = true,
    -- Themed rounds set promote to 0: main.lua expands promote into promoted types after this hook, which would break the theme.
    transform = function(p)
      for i, e in ipairs(p.entries) do
        e.proto = cycle(POOL.horde, i)
        e.count = e.count * 2
        e.promote = 0
      end
      p.promote = 0
      p.gapMult = 0.75
    end,
  },
  {
    id = "iron-wall", title = "IRON WALL!", line = "Armored squads incoming.", kind = "special", weight = 10, minRound = 3, additive = false, available = true,
    -- Classic form: two squads of 3 from the iron pool, added to the stock round.
    classic = function() return { entries = squads(POOL.iron, 2, 3) } end,
    transform = function(p)
      for i, e in ipairs(p.entries) do
        e.proto = cycle(POOL.iron, i)
        e.count = math.max(1, math.ceil(e.count / 2))
        e.promote = 0
      end
      p.promote = 0
    end,
  },
  {
    id = "sapper-rush", title = "SAPPER RUSH!", line = "Bomb squads incoming.", kind = "special", weight = 10, minRound = 3, additive = false, available = true,
    -- Classic form: two squads of 4 from the sapper pool.
    classic = function() return { entries = squads(POOL.sapper, 2, 4) } end,
    transform = function(p)
      for i, e in ipairs(p.entries) do
        e.proto = cycle(POOL.sapper, i)
        e.promote = 0
      end
      p.promote = 0
      p.gapMult = 0.75
    end,
  },
  {
    id = "firestorm", title = "FIRESTORM!", line = "Fire fiend squads incoming.", kind = "special", weight = 10, minRound = 3, additive = false, available = true,
    -- Classic form: two squads of 4 from the fire pool.
    classic = function() return { entries = squads(POOL.fire, 2, 4) } end,
    transform = function(p)
      for i, e in ipairs(p.entries) do
        e.proto = cycle(POOL.fire, i)
        e.promote = 0
      end
      p.promote = 0
    end,
  },
  {
    id = "mystic-circle", title = "MYSTIC CIRCLE", line = "Casters and shamans incoming.", kind = "special", weight = 10, minRound = 3, additive = false, available = true,
    -- Classic form: one OrcMedium and two squads of 2 from the mystic pool.
    classic = function()
      local out = { { proto = "OrcMedium", count = 1 } }
      for _, e in ipairs(squads(POOL.mystic, 2, 2)) do out[#out + 1] = e end
      return { entries = out }
    end,
    transform = function(p)
      for i, e in ipairs(p.entries) do
        if i == 1 then
          e.proto = "OrcMedium"
        else
          e.proto = cycle(POOL.mystic, i - 1)
        end
        e.promote = 0
      end
      p.promote = 0
    end,
  },
  {
    id = "treasure-herd", title = "TREASURE HERD", line = "Loot goblins and a Moneybags.", kind = "special", weight = 2, minRound = 3, additive = false, available = true,
    -- Classic form: two LootGoblin and one OgreMoneybags. The Moneybags pays 500 on death only.
    classic = function()
      return { entries = { { proto = POOL.herd[1], count = 1 }, { proto = POOL.herd[1], count = 1 }, { proto = POOL.herd[2], count = 1 } } }
    end,
    transform = function(p)
      for i, e in ipairs(p.entries) do
        if i % 2 == 0 then
          e.proto = cycle(POOL.herd, i // 2)
        else
          e.proto = "OrcLight"
        end
        e.promote = 0
      end
      p.promote = 0
    end,
  },
  {
    id = "elite-guard", title = "ELITE GUARD", line = "Some squads hold elite types.", kind = "special", weight = 10, minRound = 3, additive = false, available = true,
    -- Classic form: two single elites from the elite pool, picked from the match seed and the round.
    classic = function(ctx)
      local rng = M.Rng((ctx and ctx.seed) or 0, ((ctx and ctx.round) or 0) + 1299709)
      local out = {}
      for i = 1, 2 do out[i] = { proto = POOL.elite[math.floor(rng() * #POOL.elite) + 1], count = 1 } end
      return { entries = out }
    end,
    -- Elite types do not promote. Some entries swap to an elite proto; counts stay the same.
    transform = function(p, ctx)
      local rng = M.Rng((ctx and ctx.seed) or 0, ((ctx and ctx.round) or p.round or 0) + 7919)
      local changed, firstOpen = 0, nil
      for _, e in ipairs(p.entries) do
        if not BOSS[e.proto] then
          firstOpen = firstOpen or e
          if rng() < ELITE_CHANCE then
            e.proto = POOL.elite[math.floor(rng() * #POOL.elite) + 1]
            changed = changed + 1
          end
        end
      end
      -- A forced round always shows the effect: change the first non-boss entry.
      if changed == 0 and firstOpen then
        firstOpen.proto = POOL.elite[math.floor(rng() * #POOL.elite) + 1]
      end
    end,
  },
  {
    id = "one-gate", title = "ONE GATE", line = "Every pawn uses one doorway.", kind = "special", weight = 10, minRound = 3, additive = false, available = true,
    transform = function(p)
      p.pinDoor = true
    end,
  },
  {
    id = "blitz", title = "BLITZ!", line = "Shorter gaps between squads.", kind = "pace", weight = 10, minRound = 3, additive = false, available = true,
    transform = function(p)
      p.gapMult = 0.5
    end,
  },
  {
    -- One banner bearer. Its door sends a reinforcement call every 15 s while it stands.
    id = "war-banner", title = "WAR BANNER", line = "A banner bearer calls reinforcements.", kind = "reinforce", weight = 10, minRound = 3, additive = false, available = true,
    -- Classic form: one bearer and its reinforce block, the same as Reforged.
    classic = function()
      return { entries = { { proto = POOL.bearer[1], count = 1, bearer = true } },
        reinforce = { every = 15, everyCrowd = 15, count = 3, limit = 8, protos = clone(POOL.reinforce) } }
    end,
    transform = function(p)
      p.entries[#p.entries + 1] = { proto = POOL.bearer[1], count = 1, promote = 0, bearer = true }
      p.reinforce = { every = 15, everyCrowd = 15, count = 3, limit = 8, protos = clone(POOL.reinforce) }
    end,
  },
  {
    -- Three bearers on three doors. Calls come every 15 s, and every 10 s while 2 or more bearers stand.
    id = "warcamp", title = "WARCAMP!", line = "Three banner bearers call reinforcements.", kind = "reinforce", weight = 3, minRound = 6, additive = false, available = true,
    -- Classic form: three bearers and the reinforce block, the same as Reforged.
    classic = function()
      local out = {}
      for i = 1, 3 do out[i] = { proto = POOL.bearer[1], count = 1, bearer = true } end
      return { entries = out, reinforce = { every = 15, everyCrowd = 10, count = 3, limit = 8, protos = clone(POOL.reinforce) } }
    end,
    transform = function(p)
      for _ = 1, 3 do
        p.entries[#p.entries + 1] = { proto = POOL.bearer[1], count = 1, promote = 0, bearer = true }
      end
      p.reinforce = { every = 15, everyCrowd = 10, count = 3, limit = 8, protos = clone(POOL.reinforce) }
    end,
  },
  {
    id = "ambush", title = "AMBUSH!", line = "Skips the break.", kind = "pace", weight = 5, minRound = 3, additive = false, available = false,
    transform = function(p)
      p.skipBreak = true
    end,
  },
}

local BY_ID = {}
for _, rec in ipairs(REG) do BY_ID[rec.id] = rec end

-- Registry view, in registry order.
function M.List()
  local out = {}
  for i, rec in ipairs(REG) do
    out[i] = { id = rec.id, kind = rec.kind, weight = rec.weight, minRound = rec.minRound,
                additive = rec.additive, available = rec.available }
  end
  return out
end

function M.Get(id)
  return BY_ID[id]
end

-- Banner text for one id: title (ASCII, at most 20 characters) and line (ASCII, at most 48), or nil for an unknown id.
function M.Banner(id)
  local rec = BY_ID[id]
  if not rec then return nil end
  return rec.title, rec.line
end

-- Returns a new plan with the modifier applied, or nil and an error string.
function M.Apply(id, plan, ctx)
  local rec = BY_ID[id]
  if not rec then return nil, "unknown modifier: " .. tostring(id) end
  local p = clone(plan)
  p.modifier = id
  rec.transform(p, ctx)
  return p
end

-- Picks one modifier id for this round, or nil.
function M.Roll(ctx, opts)
  opts = opts or {}
  local chance = opts.chance or 20
  local minRound = opts.minRound or 3
  local disabled = opts.disabled or {}
  local classicOn = opts.classicOn == true
  local mode = ctx.mode

  if mode == "manual" then return nil end
  if mode == "classic" and not classicOn then return nil end
  if ctx.boss then return nil end
  if ctx.round < minRound then return nil end

  local rng = M.Rng(ctx.seed, ctx.round)
  local r1 = rng()
  if r1 * 100 >= chance then return nil end

  local cands, total = {}, 0
  for _, rec in ipairs(REG) do
    local ok = rec.available and not disabled[rec.id] and rec.id ~= opts.last and rec.minRound <= ctx.round
    if mode == "classic" then ok = ok and rec.additive end
    if ok then
      cands[#cands + 1] = rec
      total = total + rec.weight
    end
  end
  if #cands == 0 then return nil end

  local target = rng() * total
  local acc = 0
  for _, rec in ipairs(cands) do
    acc = acc + rec.weight
    if target < acc then return rec.id end
  end
  return cands[#cands].id
end

-- Picks one Classic modifier id for this round, or nil. Same chance, minRound and last rules as M.Roll.
-- Only rows with a classic field can be picked. Horde, one-gate, blitz and ambush have none, so they are never picked.
-- M.Roll keeps its own classic branch (no additive rows), so Classic rolls go through this function.
function M.RollClassic(ctx, opts)
  opts = opts or {}
  local chance = opts.chance or 20
  local minRound = opts.minRound or 3
  local disabled = opts.disabled or {}

  if ctx.mode ~= "classic" then return nil end
  if ctx.boss then return nil end
  if ctx.round < minRound then return nil end

  local rng = M.Rng(ctx.seed, ctx.round)
  local r1 = rng()
  if r1 * 100 >= chance then return nil end

  local cands, total = {}, 0
  for _, rec in ipairs(REG) do
    local ok = rec.classic ~= nil and rec.available and not disabled[rec.id] and rec.id ~= opts.last and rec.minRound <= ctx.round
    if ok then
      cands[#cands + 1] = rec
      total = total + rec.weight
    end
  end
  if #cands == 0 then return nil end

  local target = rng() * total
  local acc = 0
  for _, rec in ipairs(cands) do
    acc = acc + rec.weight
    if target < acc then return rec.id end
  end
  return cands[#cands].id
end

-- The Classic form of one modifier: { id, entries, reinforce? }, or nil when the id has no classic field.
-- entries are added to the stock round: { proto, count, bearer? }. reinforce is a copy of the reinforce block, or nil.
function M.Classic(id, ctx)
  local rec = BY_ID[id]
  if not rec or type(rec.classic) ~= "function" then return nil end
  local form = rec.classic(ctx or {})
  local entries = {}
  for i, e in ipairs(form.entries) do
    entries[i] = { proto = e.proto, count = e.count, bearer = e.bearer }
  end
  return { id = id, entries = entries, reinforce = form.reinforce and clone(form.reinforce) or nil }
end

-- Entry and pawn counts before and after a transform.
function M.Summary(before, after)
  local function pawns(p)
    local n = 0
    for _, e in ipairs(p.entries or {}) do n = n + (e.count or 0) end
    return n
  end
  return {
    entriesBefore = #(before.entries or {}),
    entriesAfter = #(after.entries or {}),
    pawnsBefore = pawns(before),
    pawnsAfter = pawns(after),
  }
end

-- Every proto name that a transform can write, sorted.
function M.Protos()
  local set = { OrcLight = true, OrcMedium = true }
  for _, pool in pairs(POOL) do
    for _, name in ipairs(pool) do set[name] = true end
  end
  local out = {}
  for name in pairs(set) do out[#out + 1] = name end
  table.sort(out)
  return out
end

return M
