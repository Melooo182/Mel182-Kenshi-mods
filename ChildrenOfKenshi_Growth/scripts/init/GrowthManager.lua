-- GrowthManager.lua
-- Timestamp-driven child growth with sex-conditional sliders, per-slider
-- growth curves, and an optional race swap (with head mapping) at maturity.
-- Mirrors BaseScript.lua's write pattern: getAppearance() ->
-- appearanceData.fdata -> updatedAppearanceData = true.
-- No setAppearanceData anywhere.
--
-- HISTORY OF DESIGN DECISIONS (kept for reference):
--
-- * Race entries are keyed by FCS race stringID (stable across
--   renames), not display name. character.myRace.data.stringID
--   returns the key we match against.
--
-- * Per-NPC overrides via growthConfig.npcOverrides, keyed by FCS
--   template stringID (character:getGameData().stringID) with a
--   handle:toString() fallback for dynamically-spawned characters.
--   The override field is `growthTimeMultiplier`, a scale factor on
--   the character's own cfg.growthDays:
--     1.0        = normal pace
--     0.5        = half duration (grows twice as fast)
--     1.2        = 20% longer
--     2.0        = double duration
--     "full"     = already mature, no growth
--   (Earlier versions used `headstartDays` in absolute days; that
--   was replaced by the multiplier for portability across races.)
--
-- * Growth is purely timestamp-driven: GrowthBirthDay is the single
--   source of truth. t = (currentDay - GrowthBirthDay) / effectiveDays,
--   clamped to [0,1]. No height scanning.
--
-- * Sliders can specify sex = "male" / "female" / "both" (or omit
--   for "both"). Duplicate slider names for different sexes are
--   expected; SliderAppliesTo filters which entry each character
--   actually uses.
--
-- * Tagging for imported/old-save characters uses an estimator that
--   averages implied t across the character's current slider values
--   against the config's from/to ranges (inverting each slider's
--   curve). This is how an old-save child starts mid-growth rather
--   than at t=0.
--
-- * Auto-tagging runs every tick for untagged child-race characters.
--   This covers: old saves, new saves, recruited NPCs, modded
--   spawns, imports. A per-character bdata.GrowthMature flag prevents
--   re-checking characters that are already fully grown.
--
-- * STORAGE TYPING: fdata = floats, sdata = strings, bdata = booleans,
--   idata = integers. The binding enforces these strictly:
--     fdata.GrowthBirthDay / GrowthLastCheckedDay / GrowthStart_* : number
--     sdata.GrowthRaceKey                                         : string
--     bdata.GrowthMature                                          : boolean
--   Putting a boolean in fdata throws "number expected, got boolean"
--   and prevents the rest of the function from running. Keep the
--   GrowthMature flag in bdata.
--
-- * We do NOT call setAppearanceData anywhere. The write path is
--   getAppearance() -> appearanceData.fdata -> set field ->
--   AppDataBase.updatedAppearanceData = true. This mirrors the
--   reference BaseScript.lua and was confirmed to work in-game.
--   Earlier versions called Character:setAppearanceData(...) and
--   that was implicated in a CTD. Do not reintroduce it without
--   testing in isolation.
--
-- * Per-slider growth curves (smoothstep / easeOutQuad / linear) are
--   applied in GrowCharacter. Anything that runs the other way
--   (EstimateGrowthFraction, and the start value computed in
--   TagCharacterEstimated) uses the inverse curve / ComputeStart so
--   characters tagged mid-growth do not jump on their first tick.
--   Characters tagged BEFORE the curve change keep their old start
--   values; untag and retag them when testing.
--
-- * RACE SWAP AT MATURITY (Lua only, confirmed by in-game tests and by
--   inspecting the savegame file):
--     - Character:setRace(target) ALONE only changes the live race
--       pointer. Stats follow it, but the mesh, the editor and the save
--       keep the old race, and a reload reverts it.
--     - The saved race is the "race" reference list inside the
--       character's appearance data. Rewriting it makes the swap persist:
--         ad:clearList("race")
--         ad:addToList("race", target.stringID, 0, 0, 0)
--         ad:getGameDataReferenceObject("race", target.stringID).ptr = target
--       (the same thing the RaceChange C++ plugin does; it additionally
--       wipes the appearance, which we deliberately do NOT do)
--     - Sliders, gender, hair style, skin/hair tone carry over untouched.
--     - Do not call the editor as part of the swap. activateCharacterEditMode
--       only works with the game UNPAUSED (a paused game leaves a blank
--       editor you cannot leave).
--
-- * HEADS (sdata.head, a stringID string):
--     - A head that is NOT in the receiving race's head pool is replaced
--       by a random valid head immediately at swap time. A head that IS
--       in the pool is kept, including heads flagged playable = no and
--       NPC chance = 0 (tested, survives save/reload).
--     - Heads shared with the adult race in FCS therefore need no map.
--     - Randomly generated children get heads from the CHILD race pool,
--       which adult races do not have. For those, cfg.headMap maps
--       child head stringID -> adult head stringID. The mapped head must
--       be in the adult race's pool or the game randomizes it again.
--     - The head is read BEFORE setRace and mapped AFTER it (the game may
--       already have replaced it during the swap).
--     - Head IDs are plain stringIDs. Do NOT wrap them in angle brackets
--       when testing from the console; that produced unreliable results.
--     - Unmapped child heads get a random adult head and a log warning
--       naming the ID, so gaps in headMap can be collected from the log.
--
-- * PER-CHARACTER TARGET RANDOMIZATION: the configured `to` value is the CENTER
--   of a distribution, not a fixed result. When a character is tagged, each
--   applicable slider gets its own target rolled once and stored in
--   fdata["GrowthTarget_<slider>"], so it is stable across ticks and
--   save/load. Config fields (all optional, default = no randomization):
--     randomRange  on the race entry or on a slider (slider wins). The target
--                  is shifted by up to +/- randomRange * |to| (0.05 on to=100
--                  means up to +/-5 points). 0 disables it for that slider.
--     group        a string. Sliders sharing a group share ONE roll, so related
--                  sliders (frame / shoulders / chest ...) move together and
--                  bodies stay coherent instead of independent noise.
--   The roll is triangular (most characters land near the designed target,
--   extremes are rare). Characters tagged before this existed have no stored
--   target and fall back to the configured `to`; untag and retag to roll.
--   Keep the extremes inside the race's slider limits.
--
-- * MATURE CHARACTERS STILL IN A CHILD RACE: any mature character whose race has
--   an adultRaceName is swapped by MaybeSwapMature (grown ones, children that
--   matured before the swap existed, recruits that were already fully grown).
--   growthTimeMultiplier = "full" overrides are deliberately skipped. A failing
--   swap sets bdata.GrowthSwapFailed so it does not retry or spam every tick;
--   GrowthManager.SwapSelected() clears the flag and tries again.
--
-- * STAT PROGRESSION: the child race entries in FCS already carry the child
--   baseline (lower HP / speed / strength ...). While a character grows, groups
--   of stats are scaled UP (or down) toward cfg.statEnd[group]: multiplier
--   m(t) = lerp(1.0, endMult, t), applied as a ratio against the CURRENT value so
--   training done in between is kept. The last applied multiplier is stored in
--   fdata["GrowthMult_<group>"]. Groups: limbs (limb max health), strength,
--   toughness, athletics, swimming, dexterity, perception, combat. There is no
--   known Lua field for movement/combat speed, so athletics / swimming /
--   dexterity act as stand-ins. cfg.statCurve (default "linear") shapes m(t).
--   At maturity the final multiplier is KEPT, except for groups listed in
--   cfg.statRevert, which are undone (use it if the race swap already re-derives
--   that value from the adult race, to avoid counting it twice; GrowthManager.
--   ProbeStats() before and after SwapSelected() on a child shows whether it does).
--   Aborts (race mismatch, UntagSelected) undo everything applied so far.
--   NPC children need no Lua: their baseline lives in the child race in FCS.
--   TESTED: the ramp math is exact (apply then undo returns the original values);
--   stats.toughness is a function, not a number, so it cannot be scaled (do not list it);
--   Character:setRace re-derives limb max health from the new race (a child at 80 became the
--   adult race's 100 at the swap), so at maturity the swap sets limb health by itself, a
--   race-mismatch abort leaves limbs alone, and statRevert is not needed for limbs.
--   TESTED (save/reload): numeric stats persist, but limb _maxHealth does NOT: it reverts to
--   the race base on load while flesh keeps its saved value. Limbs therefore use an absolute
--   baseline (fdata["GrowthLimbBase_<limb>"]) re-asserted every pass, see ScaleLimbs. The limb
--   ramp only lasts while the character is growing: at maturity the swap sets the adult
--   value; a race with swapOnMaturity = false would lose its limb bonus on the next reload,
--   so leave `limbs` out of statEnd for such a race.
--
-- * SLIDER KEYS: fdata keys must match the game's keys exactly (case-sensitive).
--   A wrong key silently writes an unused value. TagCharacterEstimated /
--   TagSelected warn once per session when a character has no value for a
--   configured slider. GrowthManager.DumpFdata("filter") lists a selected
--   character's real keys and values.
--
-- * Not applied yet: the maturity dialogue.

-- This method of calling the config will cause conflict with Steam workshop's way of handling mods folders
--local growthConfig = dofile("mods/ChildrenOfKenshi_Growth/scripts/config/growth_config.lua")
-- ---------------------------------------------------------------
-- ---------------------------------------------------------------
-- Now the content of growth_config.lua had been moved into the same script but at top of the file.
-- ---------------------------------------------------------------
-- ---------------------------------------------------------------

-- Per race entry in growth_config.lua (adultRaceName / adultRaceID already exist):
--   swapOnMaturity = true,   -- optional, default true when adultRaceName is set.
--                            -- false = grow proportions only, keep the child race
--   headMap = {              -- optional, see HEADS above
--     ["CHILD_HEAD_STRINGID"] = "ADULT_HEAD_STRINGID",
--   },
--   randomRange = 0.05,      -- optional default for every slider of this race
--   -- and per slider (all optional):
--   --   { name = "Frame", from = 80, to = 100, curve = "linear",
--   --     sex = "male", randomRange = 0.06, group = "build" },
--   --   randomRange = 0 on a slider turns randomization off for it.

local GrowthManager = {}

-- ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
-- ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
-- CONFIG STARTS HERE
-- ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
-- ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
local growthConfig = {}

-- Stat progression (applied by GrowthManager.lua): each group's multiplier goes from 1.0 at the
-- start of growth to these values at maturity, linearly (add statCurve = "smoothstep" etc. to a
-- race to change the shape). The child races already start lower in FCS; these ramps bring
-- them up to adult level. XP gain and regen/heal stay on the race in FCS, untouched.
-- Optional per race: statRevert = { "limbs" } undoes a group at maturity. Use it only if the race
-- swap itself already sets that value from the adult race (check with GrowthManager.ProbeStats()
-- before and after GrowthManager.SwapSelected()). Per-race statEnd = {...} overrides the default.
-- Known: the swap re-derives limb health from the adult race, so limbs need no statRevert.
local DefaultStatEnd = {
  limbs      = 1.25,   -- limb max health
  athletics  = 1.09,   -- stand-in for movement speed
  swimming   = 1.09,
  strength   = 1.09,
  dexterity  = 0.91,
  perception = 0.91,
  -- no toughness: stats.toughness is a function in the Lua binding, not a number
}

-- Race entries keyed by FCS race stringID (stable across renames).
-- These match character.myRace.data.stringID.
--
-- Randomization (rolled ONCE per character when it is tagged, see GrowthManager.lua):
--   randomRange  on a race entry = default for all its sliders; on a slider it overrides.
--                The target becomes `to` +/- up to (randomRange * |to|) points. 0 = off.
--   group        sliders with the same group string share one roll, so they move together
--                (build = frame/shoulders/chest/arms, size = height/legs length,
--                lower = legs bulk/waist/hips).
growthConfig["1535099-ChildrenOfKenshi.mod"] = {   -- Greenlander Child
  growthDays = 3, -- Default is 350
  adultRaceName = "Greenlander",
  adultRaceID   = "17-gamedata.quack",
  randomRange = 0.05,   -- default for this race's sliders (+/- fraction of each target)
  statEnd = DefaultStatEnd,
  sliders = {
    -- Applies to both sexes
    { name = "Height",      from = 80, to = 100, curve = "smoothstep", group = "size" },
    { name = "Leg length", from = 95, to = 100, curve = "smoothstep", randomRange = 0.03, group = "size" },
    { name = "Feet",   from = 90, to = 100, curve = "linear", randomRange = 0.03 },
    { name = "Hands",   from = 92, to = 100, curve = "linear", randomRange = 0.03 },
    { name = "Head size",   from = 80, to = 97, curve = "easeOutQuad", randomRange = 0.02 },
    { name = "Neck",   from = 80, to = 100, curve = "easeOutQuad", randomRange = 0.04 },
    { name = "Neck width",   from = 80, to = 100, curve = "easeOutQuad", randomRange = 0.04 },
    { name = "Neck length",   from = 70, to = 85, curve = "smoothstep", randomRange = 0.04 },

    -- Diverges by sex
    { name = "Frame",       from = 80, to = 100, curve = "linear", sex = "male", group = "build" },
    { name = "Frame",       from = 80, to =  95, curve = "linear", sex = "female", group = "build" },
    { name = "Shoulders",       from = 85, to = 103, curve = "linear", sex = "male", group = "build" },
    { name = "Shoulders",       from = 85, to =  100, curve = "linear", sex = "female", group = "build" },
    { name = "Chest",   from = 70, to = 105, curve = "smoothstep", sex = "male", group = "build" },
    { name = "Chest",   from = 80, to = 100, curve = "smoothstep", sex = "female", group = "build" },
    { name = "Waist",         from = 75, to = 100, curve = "linear",    sex = "male", group = "lower" },
    { name = "Waist",         from = 50, to = 100, curve = "linear",    sex = "female", group = "lower" },
    { name = "high_eyes",   from = -0.60, to = -0.25, curve = "easeOutQuad", sex = "male", randomRange = 0.10 },
    { name = "high_eyes",   from = -0.60, to = -0.35, curve = "easeOutQuad", sex = "female", randomRange = 0.10 },

    -- Arm bulk: males heavier, females lighter
    { name = "Arm bulk",    from = 80, to = 100, curve = "linear", sex = "male", group = "build" },
    { name = "Arm bulk",    from = 80, to =  90, curve = "linear", sex = "female", group = "build" },

    -- Legs bulk: opposite ? females higher
    { name = "Legs bulk",   from = 85, to = 105, curve = "linear", sex = "male", group = "lower" },
    { name = "Legs bulk",   from = 85, to = 110, curve = "linear", sex = "female", group = "lower" },

    -- Female-only
    { name = "Breast size",   from = 30, to = 95, curve = "smoothstep", sex = "female", randomRange = 0.08 },
    { name = "Breast height", from = 120, to = 100, curve = "linear",     sex = "female", randomRange = 0.03 },
    { name = "Hips",          from = 80, to = 100, curve = "linear",     sex = "female", group = "lower" },

    -- Male-only
  },
  -- Table for Head Swaps after race successfully swapped
  headMap = {
    -- Female
    ["5007786-ChildrenOfKenshi.mod"] = "16-ChildrenOfKenshi_Growth.mod",
    ["5007514-ChildrenOfKenshi.mod"] = "17-ChildrenOfKenshi_Growth.mod",
    ["5007787-ChildrenOfKenshi.mod"] = "18-ChildrenOfKenshi_Growth.mod",
    ["5007515-ChildrenOfKenshi.mod"] = "19-ChildrenOfKenshi_Growth.mod",
    ["5007779-ChildrenOfKenshi.mod"] = "20-ChildrenOfKenshi_Growth.mod",
    ["5007400-ChildrenOfKenshi.mod"] = "21-ChildrenOfKenshi_Growth.mod",
    ["5007778-ChildrenOfKenshi.mod"] = "22-ChildrenOfKenshi_Growth.mod",
    ["5007780-ChildrenOfKenshi.mod"] = "23-ChildrenOfKenshi_Growth.mod",
	-- Male
    ["5007785-ChildrenOfKenshi.mod"] = "24-ChildrenOfKenshi_Growth.mod",
    ["5007513-ChildrenOfKenshi.mod"] = "25-ChildrenOfKenshi_Growth.mod",
    ["5007788-ChildrenOfKenshi.mod"] = "26-ChildrenOfKenshi_Growth.mod",
    ["5007516-ChildrenOfKenshi.mod"] = "27-ChildrenOfKenshi_Growth.mod",
    ["5007784-ChildrenOfKenshi.mod"] = "28-ChildrenOfKenshi_Growth.mod",
    ["5007781-ChildrenOfKenshi.mod"] = "29-ChildrenOfKenshi_Growth.mod",
    ["5007782-ChildrenOfKenshi.mod"] = "30-ChildrenOfKenshi_Growth.mod",
    ["5007783-ChildrenOfKenshi.mod"] = "31-ChildrenOfKenshi_Growth.mod",
  },
}

growthConfig["1535459-ChildrenOfKenshi.mod"] = {   -- Scorchlander Child
  growthDays = 3, -- Default is 350
  adultRaceName = "Scorchlander",
  adultRaceID   = "18019-gamedata.base",
  randomRange = 0.04,   -- default for this race's sliders (+/- fraction of each target)
  statEnd = DefaultStatEnd,
  sliders = {
    -- Applies to both sexes
    { name = "Height",      from = 80, to = 95, curve = "smoothstep", group = "size" },
    { name = "Leg length", from = 80, to = 96, curve = "smoothstep", randomRange = 0.03, group = "size" },
    { name = "Feet",   from = 90, to = 100, curve = "linear", randomRange = 0.03 },
    { name = "Hands",   from = 92, to = 98, curve = "linear", randomRange = 0.03 },
    { name = "Head size",   from = 80, to = 97, curve = "easeOutQuad", randomRange = 0.02 },
    { name = "Neck",   from = 75, to = 85, curve = "easeOutQuad", randomRange = 0.04 },
    { name = "Neck width",   from = 80, to = 85, curve = "easeOutQuad", randomRange = 0.04 },
    { name = "Neck length",   from = 70, to = 85, curve = "smoothstep", randomRange = 0.04 },

    -- Diverges by sex
    { name = "Frame",       from = 80, to = 95, curve = "linear", sex = "male", group = "build" },
    { name = "Frame",       from = 80, to = 90, curve = "linear", sex = "female", group = "build" },
    { name = "Shoulders",       from = 85, to = 95, curve = "linear", sex = "male", group = "build" },
    { name = "Shoulders",       from = 85, to =  91, curve = "linear", sex = "female", group = "build" },
    { name = "Chest",   from = 70, to = 98, curve = "smoothstep", sex = "male", group = "build" },
    { name = "Chest",   from = 80, to = 95, curve = "smoothstep", sex = "female", group = "build" },
    { name = "Waist",         from = 75, to = 97, curve = "linear",    sex = "male", group = "lower" },
    { name = "Waist",         from = 50, to = 85, curve = "linear",    sex = "female", group = "lower" },
    { name = "high_eyes",   from = -0.60, to = -0.25, curve = "easeOutQuad", sex = "male", randomRange = 0.10 },
    { name = "high_eyes",   from = -0.60, to = -0.35, curve = "easeOutQuad", sex = "female", randomRange = 0.10 },

    -- Arm bulk: males heavier, females lighter
    { name = "Arm bulk",    from = 80, to = 100, curve = "linear", sex = "male", group = "build" },
    { name = "Arm bulk",    from = 80, to =  90, curve = "linear", sex = "female", group = "build" },

    -- Legs bulk: opposite ? females higher
    { name = "Legs bulk",   from = 80, to = 90, curve = "linear", sex = "male", group = "lower" },
    { name = "Legs bulk",   from = 80, to = 95, curve = "linear", sex = "female", group = "lower" },

    -- Female-only
    { name = "Breast size",   from = 30, to = 77, curve = "smoothstep", sex = "female", randomRange = 0.08 },
    { name = "Breast height", from = 120, to = 125, curve = "linear",     sex = "female", randomRange = 0.03 },
    { name = "Hips",          from = 85, to = 100, curve = "linear",     sex = "female", group = "lower" },

    -- Male-only
  },
  -- Table for Head Swaps after race successfully swapped
  headMap = {
    -- Female
    ["5007515-ChildrenOfKenshi.mod"] = "19-ChildrenOfKenshi_Growth.mod",
    ["5007779-ChildrenOfKenshi.mod"] = "20-ChildrenOfKenshi_Growth.mod",
    ["5007780-ChildrenOfKenshi.mod"] = "23-ChildrenOfKenshi_Growth.mod",
	-- Male
    ["5007516-ChildrenOfKenshi.mod"] = "27-ChildrenOfKenshi_Growth.mod",
    ["5007784-ChildrenOfKenshi.mod"] = "28-ChildrenOfKenshi_Growth.mod",
    ["5007783-ChildrenOfKenshi.mod"] = "31-ChildrenOfKenshi_Growth.mod",
  },
}

growthConfig["1535457-ChildrenOfKenshi.mod"] = {   -- Shek Child
  growthDays = 3, -- Default is 400
  adultRaceName = "Shek",
  adultRaceID   = "5276-chareditor.mod",
  randomRange = 0.06,   -- default for this race's sliders (+/- fraction of each target)
  statEnd = DefaultStatEnd,
  sliders = {
    -- Applies to both sexes
    { name = "Height",      from = 85, to = 110, curve = "smoothstep", group = "size" },
    { name = "Leg length", from = 95, to = 100, curve = "smoothstep", randomRange = 0.03, group = "size" },
    { name = "Feet",   from = 90, to = 100, curve = "linear", randomRange = 0.03 },
    { name = "Hands",   from = 93, to = 102, curve = "linear", randomRange = 0.03 },
    { name = "Head size",   from = 80, to = 97, curve = "easeOutQuad", randomRange = 0.02 },
    { name = "Neck",   from = 80, to = 100, curve = "easeOutQuad", randomRange = 0.02 },
    { name = "Neck width",   from = 80, to = 100, curve = "easeOutQuad", randomRange = 0.02 },
    { name = "Neck length",   from = 70, to = 85, curve = "smoothstep", randomRange = 0.04 },
	
	-- Shek-only (horn values are shortness on a 0..1 scale: lower = LONGER horns)
    { name = "bone_horns_top_short",    from = 0.85, to = 0.50, curve = "linear", randomRange = 0.10 },
    { name = "bone_horns_bottom_short", from = 0.85, to = 0.50, curve = "linear", randomRange = 0.10 },
    { name = "bone_horns_body_short",   from = 0.75, to = 0.50, curve = "linear", randomRange = 0.10 },

    -- Diverges by sex
    { name = "Frame",       from = 87, to = 110, curve = "linear", sex = "male", group = "build" },
    { name = "Frame",       from = 85, to =  100, curve = "linear", sex = "female", group = "build" },
    { name = "Shoulders",       from = 85, to = 105, curve = "linear", sex = "male", group = "build" },
    { name = "Shoulders",       from = 85, to =  100, curve = "linear", sex = "female", group = "build" },
    { name = "Chest",   from = 65, to = 108, curve = "smoothstep", sex = "male", group = "build" },
    { name = "Chest",   from = 80, to = 103, curve = "smoothstep", sex = "female", group = "build" },
    { name = "Waist",         from = 75, to = 100, curve = "linear",    sex = "male", group = "lower" },
    { name = "Waist",         from = 50, to = 100, curve = "linear",    sex = "female", group = "lower" },
    { name = "bone_high_eyes",   from = -0.30, to = -0.05, curve = "easeOutQuad", sex = "male", randomRange = 0.10 },
    { name = "bone_high_eyes",   from = -0.30, to = -0.15, curve = "easeOutQuad", sex = "female", randomRange = 0.10 },

    -- Arm bulk: males heavier, females lighter
    { name = "Arm bulk",    from = 83, to = 115, curve = "linear", sex = "male", group = "build" },
    { name = "Arm bulk",    from = 80, to =  105, curve = "linear", sex = "female", group = "build" },

    -- Legs bulk: opposite ? females higher
    { name = "Legs bulk",   from = 85, to = 110, curve = "linear", sex = "male", group = "lower" },
    { name = "Legs bulk",   from = 85, to = 120, curve = "linear", sex = "female", group = "lower" },

    -- Female-only
    { name = "Breast size",   from = 40, to = 120, curve = "smoothstep", sex = "female", randomRange = 0.08 },
    { name = "Breast height", from = 120, to = 110, curve = "linear",     sex = "female", randomRange = 0.03 },
    { name = "Hips",          from = 80, to = 110, curve = "linear",     sex = "female", group = "lower" },

    -- Male-only
  },
  -- Table for Head Swaps after race successfully swapped
  headMap = {
  },
}

-- -----------------------------------------------------------------
-- Per-NPC headstarts or delays
growthConfig.npcOverrides = {
  -- Normal pace (default, no override needed):
  -- ["12345-somebody.mod"] = { growthTimeMultiplier = 1.0 },
  -- Grows twice as fast (200 days instead of 400):
  --["22222-quick.mod"] = { growthTimeMultiplier = 0.5 },
  -- 20% slower (480 days):
 -- ["33333-slow.mod"] = { growthTimeMultiplier = 1.2 },
  -- Very slow (800 days):
  --["44444-ancient.mod"] = { growthTimeMultiplier = 2.0 },
  -- Never grows (marked mature on first sight):
  --["55555-adult.mod"] = { growthTimeMultiplier = "full" },
}

--return growthConfig -- commented out since it's no longer needed since the config is now hosted in the same script.
-- ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
-- ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
-- CONFIG ENDS HERE
-- ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
-- ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++

local function GetCurrentTime()
  return getGameWorld():getTimeStamp_inGameHours():getTotalDays()
end

local function LerpFloat(A, B, LerpVal)
  return A + (LerpVal * (B - A))
end


-- growth_curves_patch.lua
-- Changes so the per-slider `curve` field in growth_config.lua is
-- actually used.
-- NOTE: sections 1-4 below are APPLIED in the code of this file; the
-- commented blocks are kept as documentation. Section 5 (stat scaling)
-- is applied too, with the inverted semantics described in STAT PROGRESSION.
--
-- Two things to handle, not just one:
--   1. GrowCharacter must run t through the slider's curve.
--   2. Anything that goes the other way (estimating t from current slider
--      values, and computing the start value for a mid-growth character)
--      must use the curve too, or characters tagged mid-growth jump.

---------------------------------------------------------------
-- 1) Paste near the top, below LerpFloat
---------------------------------------------------------------
local Curves = {
  linear      = function(t) return t end,
  smoothstep  = function(t) return t * t * (3 - 2 * t) end,
  easeOutQuad = function(t) return 1 - (1 - t) * (1 - t) end,
}

-- Inverses: given a curved value y in 0..1, return the t that produced it.
local CurveInverses = {
  linear      = function(y) return y end,
  smoothstep  = function(y) return 0.5 - math.sin(math.asin(1 - 2 * y) / 3) end,
  easeOutQuad = function(y) return 1 - math.sqrt(1 - y) end,
}

local function Clamp01(x)
  if x < 0 then return 0 end
  if x > 1 then return 1 end
  return x
end

local function ApplyCurve(name, t)
  return (Curves[name] or Curves.linear)(Clamp01(t))
end

local function InvertCurve(name, y)
  return (CurveInverses[name] or CurveInverses.linear)(Clamp01(y))
end

-- Start value such that lerp(start, to, curve(t0)) equals `cur` right now.
-- For a fresh tag (t0 = 0, so c0 = 0) this is just `cur`.
local function ComputeStart(cur, to, c0)
  if c0 >= 0.999 then return cur end
  return (cur - to * c0) / (1 - c0)
end

---------------------------------------------------------------
-- 2) EstimateGrowthFraction: replace the inner block  [APPLIED below]
---------------------------------------------------------------
-- was:  local t = (cur - slider.from) / (slider.to - slider.from)
--       (then clamp)
-- now:
--   local y = Clamp01((cur - slider.from) / (slider.to - slider.from))
--   local t = InvertCurve(slider.curve, y)
-- and use `t` for sum/count exactly as before.

---------------------------------------------------------------
-- 3) TagCharacterEstimated: replace the GrowthStart_ loop  [APPLIED below]
---------------------------------------------------------------
--   for _, slider in ipairs(cfg.sliders) do
--     if SliderAppliesTo(slider, Character) then
--       local cur = fdata[slider.name] or slider.from
--       local c0 = ApplyCurve(slider.curve, t0)
--       fdata["GrowthStart_" .. slider.name] = ComputeStart(cur, slider.to, c0)
--     end
--   end
--
-- TagSelected can keep its current loop: t0 is 0 there, so the start value
-- is the current value either way.

---------------------------------------------------------------
-- 4) GrowCharacter: replace the slider loop  [APPLIED below]
---------------------------------------------------------------
--   for _, slider in ipairs(cfg.sliders) do
--     if SliderAppliesTo(slider, Character) then
--       local Start = fdata["GrowthStart_" .. slider.name] or slider.from
--       local c = ApplyCurve(slider.curve, Lerp)
--       fdata[slider.name] = LerpFloat(Start, slider.to, c)
--     end
--   end

---------------------------------------------------------------
-- 5) Stat scaling: pick one curve for all stat groups  [APPLIED, see STAT PROGRESSION]
---------------------------------------------------------------
--   ApplyStatScale(Character, cfg, ApplyCurve(cfg.statCurve or "linear", Lerp))
-- and in TagCharacterEstimated:
--   ApplyStatScale(Character, cfg, ApplyCurve(cfg.statCurve or "linear", t0))
-- `statCurve` is an optional string field on each race entry in growth_config.lua.

local function CharacterID(Character)
  local gd = Character:getGameData()
  if gd and gd.stringID and gd.stringID ~= "" then
    return gd.stringID
  end
  return "handle:" .. tostring(Character.handle:toString())
end

local function GetOverride(Character)
  local overrides = growthConfig.npcOverrides
  if not overrides then return nil end
  return overrides[CharacterID(Character)]
end

local function GetEffectiveGrowthDays(Character, cfg)
  local override = GetOverride(Character)
  if override
     and type(override.growthTimeMultiplier) == "number"
     and override.growthTimeMultiplier > 0 then
    return cfg.growthDays * override.growthTimeMultiplier
  end
  return cfg.growthDays
end

local function SliderAppliesTo(slider, Character)
  local s = slider.sex
  if not s or s == "both" then return true end
  if s == "female" then return Character:isFemale() end
  if s == "male"   then return not Character:isFemale() end
  return true
end

-- Per-character randomization of slider targets (see PER-CHARACTER TARGET
-- RANDOMIZATION in the header). Seed once so sessions do not repeat the same
-- sequence; wrapped in pcall in case os is not available.
pcall(function()
  math.randomseed(os.time())
  math.random(); math.random(); math.random()
end)

-- Triangular distribution in -1..1: most rolls land near 0, extremes are rare.
local function RollSigned()
  return (math.random() + math.random()) - 1
end

-- This character's target for a slider: `to` shifted by up to
-- +/- randomRange * |to|. Sliders sharing a `group` share one roll (kept in
-- the `rolls` table for the duration of one tagging call).
local function RollTarget(slider, cfg, rolls)
  local range = slider.randomRange
  if range == nil then range = cfg.randomRange end
  if not range or range <= 0 then return slider.to end

  local key = slider.group
    or ("slider:" .. tostring(slider.name) .. ":" .. tostring(slider.sex))
  local roll = rolls[key]
  if roll == nil then
    roll = RollSigned()
    rolls[key] = roll
  end
  return slider.to + (math.abs(slider.to) * range * roll)
end

local function EstimateGrowthFraction(Character, cfg)
  local AppDataBase = Character:getAppearance()
  local fdata = AppDataBase.appearanceData.fdata

  local sum, count = 0, 0
  for _, slider in ipairs(cfg.sliders) do
    if SliderAppliesTo(slider, Character) then
      local cur = fdata[slider.name]
      if cur ~= nil and slider.to ~= slider.from then
        local y = Clamp01((cur - slider.from) / (slider.to - slider.from))
        local t = InvertCurve(slider.curve, y)
        sum = sum + t
        count = count + 1
      end
    end
  end

  if count == 0 then return nil end
  return sum / count
end

-- ---------------------------------------------------------------
-- Warn (once per slider name per session) when a character has no value for a
-- configured slider: usually a wrong key name, since keys are case-sensitive.
local WarnedMissing = {}
local function WarnIfSliderMissing(Character, fdata, slider)
  if fdata[slider.name] ~= nil then return end
  if WarnedMissing[slider.name] then return end
  WarnedMissing[slider.name] = true
  print("[GrowthManager] WARNING: " .. tostring(Character:getName())
    .. " has no value for slider \"" .. tostring(slider.name)
    .. "\" (wrong key name? use GrowthManager.DumpFdata to list the real keys)")
end

-- ---------------------------------------------------------------
-- STAT PROGRESSION (see header).
local StatGroups = {
  strength   = { "strength" },
  toughness  = { "toughness" },   -- NOT usable: stats.toughness is a function, not a number (skipped with a warning)
  athletics  = { "athletics" },   -- stand-in for movement speed
  swimming   = { "swimming" },
  dexterity  = { "dexterity" },
  perception = { "perception" },
  combat     = { "meleeAttack", "meleeDefence", "katanas", "sabres", "hackers",
                 "blunt", "heavyWeapons", "unarmed", "bows", "turrets", "polearms" },
}

-- Limbs use an ABSOLUTE baseline, not a ratio. The game does NOT save _maxHealth: after a
-- save/reload it reverts to the race's base value while `flesh` keeps its saved (scaled)
-- value (seen in the logs: _maxHealth=80, flesh=88.5). So every call sets
--   _maxHealth = base * newM
-- from a baseline stored in fdata, and keeps the limb's health FRACTION relative to the
-- previously intended maximum (base * lastM), never to the possibly reset live value.
-- Calling it again with the same multiplier is a no-op that repairs a reset _maxHealth.
local function ScaleLimbs(Character, fdata, lastM, newM, clearBase)
  local Anatomy = Character.medical.anatomy
  for k, limb in pairs(Anatomy) do
    local baseKey = "GrowthLimbBase_" .. tostring(k)
    local base = fdata[baseKey]
    local maxH = limb._maxHealth
    if base == nil and maxH and maxH > 0 then
      -- first sight: the live max is the unscaled race value (lastM is 1.0 on a fresh tag)
      base = (lastM > 0) and (maxH / lastM) or maxH
      fdata[baseKey] = base
    end
    if base and base > 0 then
      local prevMax = base * lastM
      local fraction = (prevMax > 0) and (limb.flesh / prevMax) or 1.0
      local newMax = base * newM
      limb._maxHealth = newMax
      limb.flesh = fraction * newMax
    end
    if clearBase then fdata[baseKey] = nil end
  end
  Character.medical.anatomy = Anatomy
end

local function ClearLimbBase(Character, fdata)
  pcall(function()
    for k, _ in pairs(Character.medical.anatomy) do
      fdata["GrowthLimbBase_" .. tostring(k)] = nil
    end
  end)
end

local WarnedStat = {}
local function ScaleStatGroup(Character, group, ratio)
  local stats = Character.stats
  for _, statName in ipairs(StatGroups[group] or {}) do
    local ok, err = pcall(function()
      local cur = stats[statName]
      if type(cur) == "number" then
        stats[statName] = cur * ratio
      elseif not WarnedStat[statName] then
        WarnedStat[statName] = true
        print("[GrowthManager] stat '" .. statName .. "' is not a plain number ("
          .. type(cur) .. "); skipped. Remove it from statEnd.")
      end
    end)
    if not ok and not WarnedStat[statName] then
      WarnedStat[statName] = true
      print("[GrowthManager] could not scale stat " .. statName .. ": " .. tostring(err))
    end
  end
end

-- t = growth fraction 0..1 (already curved). finish = true clears the stored
-- multipliers: groups in cfg.statRevert are undone first, the rest are kept at
-- their final value. ApplyStatScale(c, cfg, 0, true) therefore undoes everything.
-- skip = optional set of groups to leave untouched, e.g. { limbs = true }: only their
-- tracking key is cleared and the current value is kept.
local function ApplyStatScale(Character, cfg, t, finish, skip)
  local ends = cfg.statEnd
  if not ends then return end
  local AppDataBase = Character:getAppearance()
  if not AppDataBase or not AppDataBase.appearanceData then return end
  local fdata = AppDataBase.appearanceData.fdata
  t = Clamp01(t)

  local revert = {}
  for _, g in ipairs(cfg.statRevert or {}) do revert[g] = true end

  for group, endMult in pairs(ends) do
    local key = "GrowthMult_" .. group
    local lastM = fdata[key] or 1.0
    local newM = LerpFloat(1.0, endMult, t)
    if finish and revert[group] then newM = 1.0 end

    if group == "limbs" then
      -- absolute and re-asserted on every call, so it repairs itself after a reload
      if skip and skip[group] then
        ClearLimbBase(Character, fdata)   -- race changed: leave the limbs alone
      elseif lastM > 0 and newM > 0 then
        ScaleLimbs(Character, fdata, lastM, newM, finish)
      end
    else
      if skip and skip[group] then
        newM = lastM
      end
      if lastM > 0 and newM > 0 and math.abs(newM - lastM) > 0.0001 then
        ScaleStatGroup(Character, group, newM / lastM)
      end
    end

    if finish then fdata[key] = nil else fdata[key] = newM end
  end

  AppDataBase.updatedAppearanceData = true
end

-- Between daily recalculations, put a reset _maxHealth back (see ScaleLimbs). Cheap:
-- changes nothing when the value is already right.
local function ReassertLimbs(Character, fdata)
  local m = fdata["GrowthMult_limbs"]
  if m and m > 0 then
    ScaleLimbs(Character, fdata, m, m, false)
  end
end

local function TagCharacterEstimated(Character, currentDay, quiet)
  local AppDataBase = Character:getAppearance()
  if not AppDataBase or not AppDataBase.appearanceData then return false end

  local fdata = AppDataBase.appearanceData.fdata
  local sdata = AppDataBase.appearanceData.sdata
  local bdata = AppDataBase.appearanceData.bdata

  if sdata.GrowthRaceKey then return true end
  if bdata.GrowthMature then return true end

  local raceID = Character.myRace and Character.myRace.data
    and Character.myRace.data.stringID
  if not raceID then return false end

  local cfg = growthConfig[raceID]
  if not cfg then return false end

  local override = GetOverride(Character)
  if override and override.growthTimeMultiplier == "full" then
    bdata.GrowthMature = true
    AppDataBase.updatedAppearanceData = true
    if not quiet then
      print(string.format(
        "[GrowthManager] %s has growthTimeMultiplier=\"full\"; marked mature",
        tostring(Character:getName())))
    end
    return true
  end

  local t0 = EstimateGrowthFraction(Character, cfg)
  if t0 == nil then return false end

  if t0 >= 0.999 then
    bdata.GrowthMature = true
    AppDataBase.updatedAppearanceData = true
    if not quiet then
      print(string.format(
        "[GrowthManager] %s is already ~100%% grown; marked mature",
        tostring(Character:getName())))
    end
    return true
  end

  local effectiveDays = GetEffectiveGrowthDays(Character, cfg)
  local birthDay = currentDay - (t0 * effectiveDays)

  sdata.GrowthRaceKey = raceID
  fdata.GrowthBirthDay = birthDay
  fdata.GrowthLastCheckedDay = -1
  bdata.GrowthMature = nil

  local rolls = {}
  for _, slider in ipairs(cfg.sliders) do
    if SliderAppliesTo(slider, Character) then
      WarnIfSliderMissing(Character, fdata, slider)
      local target = RollTarget(slider, cfg, rolls)
      fdata["GrowthTarget_" .. slider.name] = target
      local cur = fdata[slider.name] or slider.from
      local c0 = ApplyCurve(slider.curve, t0)
      fdata["GrowthStart_" .. slider.name] = ComputeStart(cur, target, c0)
    end
  end
  ApplyStatScale(Character, cfg, ApplyCurve(cfg.statCurve or "linear", t0))

  AppDataBase.updatedAppearanceData = true

  if not quiet then
    if override and override.growthTimeMultiplier then
      print(string.format(
        "[GrowthManager] auto-tagged %s | raceID=%s | t0=%.3f | duration=%.1f days (multiplier %.2f)",
        tostring(Character:getName()), tostring(raceID), t0,
        effectiveDays, override.growthTimeMultiplier))
    else
      print(string.format(
        "[GrowthManager] auto-tagged %s | raceID=%s | t0=%.3f | duration=%.1f days",
        tostring(Character:getName()), tostring(raceID), t0, effectiveDays))
    end
  end
  return true
end

-- ---------------------------------------------------------------
-- Race swap at maturity. See "RACE SWAP AT MATURITY" and "HEADS" in the
-- header for why each step is done the way it is.
local function ResolveAdultRace(cfg)
  local obj = getGameWorld().gamedata:getDataByName(cfg.adultRaceName, itemType.RACE)
  if not obj then
    print("[GrowthManager] adult race lookup failed: " .. tostring(cfg.adultRaceName))
    return nil
  end
  if obj.name ~= cfg.adultRaceName then
    print("[GrowthManager] adult race NAME mismatch: wanted "
      .. tostring(cfg.adultRaceName) .. ", got " .. tostring(obj.name))
    return nil
  end
  if cfg.adultRaceID and obj.stringID ~= cfg.adultRaceID then
    print("[GrowthManager] adult race stringID mismatch: wanted "
      .. tostring(cfg.adultRaceID) .. ", got " .. tostring(obj.stringID))
    return nil
  end
  return obj
end

-- Sets sdata.head and reads it back; retries once if the game did not keep it.
local function ApplyHead(Character, headID)
  local function trySet()
    Character:getAppearanceData().sdata.head = headID
    pcall(function() Character:getAppearance().updatedAppearanceData = true end)
    return Character:getAppearanceData().sdata.head == headID
  end
  if trySet() then return true end
  return trySet()
end

local function SwapToAdultRace(Character, cfg)
  local target = ResolveAdultRace(cfg)
  if not target then return false end

  -- Read the head BEFORE the swap: the game may replace it during setRace.
  local oldHead = Character:getAppearanceData().sdata.head

  local ok, err = pcall(function() Character:setRace(target) end)
  if not ok then
    print("[GrowthManager] setRace failed: " .. tostring(err))
    return false
  end

  local ad = Character:getAppearanceData()
  local ok2, err2 = pcall(function()
    ad:clearList("race")
    ad:addToList("race", target.stringID, 0, 0, 0)
    local ref = ad:getGameDataReferenceObject("race", target.stringID)
    if ref then ref.ptr = target end
  end)
  if not ok2 then
    print("[GrowthManager] race list rewrite failed: " .. tostring(err2))
  end

  pcall(function() Character:getAppearance().raceData = target end)

  -- Head handling: map AFTER the swap.
  local mappedHead = cfg.headMap and oldHead and cfg.headMap[oldHead]
  local headNow = Character:getAppearanceData().sdata.head
  if mappedHead then
    if headNow ~= mappedHead and not ApplyHead(Character, mappedHead) then
      print("[GrowthManager] WARNING: could not apply mapped head " .. tostring(mappedHead)
        .. " (is it in the adult race's head pool?)")
    end
  elseif oldHead and headNow ~= oldHead then
    print("[GrowthManager] WARNING: child head " .. tostring(oldHead)
      .. " is not in the adult pool and was replaced with " .. tostring(headNow)
      .. ". Add it to headMap, or add the head to the adult race in FCS.")
  end

  pcall(function() Character:getAppearance().updatedAppearanceData = true end)

  print(string.format(
    "[GrowthManager] %s swapped to %s (setRace=%s, listRewrite=%s, head %s -> %s)",
    tostring(Character:getName()), tostring(target.stringID),
    tostring(ok), tostring(ok2), tostring(oldHead),
    tostring(Character:getAppearanceData().sdata.head)))

  return ok and ok2
end

-- A mature character that is still in a child race gets swapped to its adult
-- race. Covers: children who matured before the swap existed, recruits that
-- were already fully grown (estimated t0 >= 0.999), and failed-once retries
-- that were cleared with SwapSelected. Characters with
-- growthTimeMultiplier = "full" are deliberately left alone.
-- bdata.GrowthSwapFailed stops a failing swap from retrying (and spamming the
-- log) every tick.
local function MaybeSwapMature(Character)
  local raceID = Character.myRace and Character.myRace.data
    and Character.myRace.data.stringID
  local cfg = raceID and growthConfig[raceID]
  if not cfg or not cfg.adultRaceName or cfg.swapOnMaturity == false then return end

  local override = GetOverride(Character)
  if override and override.growthTimeMultiplier == "full" then return end

  local bdata = Character:getAppearance().appearanceData.bdata
  if bdata.GrowthSwapFailed then return end

  print("[GrowthManager] " .. tostring(Character:getName())
    .. " is mature but still a child race; swapping to " .. tostring(cfg.adultRaceName))
  if not SwapToAdultRace(Character, cfg) then
    bdata.GrowthSwapFailed = true
    print("[GrowthManager] swap FAILED for " .. tostring(Character:getName())
      .. "; not retrying automatically. Select them and run GrowthManager.SwapSelected().")
  end
end

-- ---------------------------------------------------------------
local function GrowCharacter(Character)
  local AppDataBase = Character:getAppearance()
  local fdata = AppDataBase.appearanceData.fdata
  local bdata = AppDataBase.appearanceData.bdata

  local BirthDay = fdata.GrowthBirthDay
  if not BirthDay then return false end

  local RaceKey = AppDataBase.appearanceData.sdata.GrowthRaceKey
  if not RaceKey then return false end

  local cfg = growthConfig[RaceKey]
  if not cfg then return false end

  if Character.myRace.data.stringID ~= RaceKey then
    print("[GrowthManager] race mismatch on " .. tostring(Character:getName())
      .. " (expected " .. tostring(RaceKey)
      .. ", found " .. tostring(Character.myRace.data.stringID) .. ")")
    fdata.GrowthBirthDay = nil
    fdata.GrowthLastCheckedDay = nil
    AppDataBase.appearanceData.sdata.GrowthRaceKey = nil
    for _, slider in ipairs(cfg.sliders) do
      fdata["GrowthStart_" .. slider.name] = nil
      fdata["GrowthTarget_" .. slider.name] = nil
    end
    -- setRace re-derives limb max health from the new race, so only the other stats
    -- are undone here; undoing limbs would shrink the new race's health.
    ApplyStatScale(Character, cfg, 0, true, { limbs = true })
    AppDataBase.updatedAppearanceData = true
    return false
  end

  local effectiveDays = GetEffectiveGrowthDays(Character, cfg)

  local CurrentTime = GetCurrentTime()
  local DayFloor = math.floor(CurrentTime)
  local NearEnd = (CurrentTime - BirthDay) >= (effectiveDays * 0.98) -- Changed from 0.95 since it gave too many ticks on last day
  if not NearEnd and fdata.GrowthLastCheckedDay == DayFloor then
    ReassertLimbs(Character, fdata)
    return true
  end
  fdata.GrowthLastCheckedDay = DayFloor

  local Elapsed = CurrentTime - BirthDay
  local Lerp = Elapsed / effectiveDays
  if Lerp < 0 then Lerp = 0 end
  if Lerp > 1 then Lerp = 1 end

  for _, slider in ipairs(cfg.sliders) do
    if SliderAppliesTo(slider, Character) then
      local Start = fdata["GrowthStart_" .. slider.name] or slider.from
      local To = fdata["GrowthTarget_" .. slider.name] or slider.to
      local c = ApplyCurve(slider.curve, Lerp)
      fdata[slider.name] = LerpFloat(Start, To, c)
    end
  end

  ApplyStatScale(Character, cfg, ApplyCurve(cfg.statCurve or "linear", Lerp))

  print(string.format("[GrowthManager] %s day=%.2f t=%.3f H=%.1f dur=%.1f",
    tostring(Character:getName()), CurrentTime, Lerp,
    fdata.Height or -1, effectiveDays))

  AppDataBase.updatedAppearanceData = true

  if Lerp >= 1.0 then
    -- Clear tags and mark mature FIRST: the race-mismatch failsafe above
    -- would otherwise fire on the very swap we are about to do.
    for _, slider in ipairs(cfg.sliders) do
      fdata["GrowthStart_" .. slider.name] = nil
      fdata["GrowthTarget_" .. slider.name] = nil
    end
    fdata.GrowthBirthDay = nil
    fdata.GrowthLastCheckedDay = nil
    AppDataBase.appearanceData.sdata.GrowthRaceKey = nil
    bdata.GrowthMature = true
    AppDataBase.updatedAppearanceData = true
    print("[GrowthManager] " .. tostring(Character:getName()) .. " matured")
    ApplyStatScale(Character, cfg, 1, true)

    if cfg.adultRaceName and cfg.swapOnMaturity ~= false then
      if not SwapToAdultRace(Character, cfg) then
        bdata.GrowthSwapFailed = true
        print("[GrowthManager] swap FAILED for " .. tostring(Character:getName())
          .. ": proportions are adult but the race is still the child race."
          .. " Select them and run GrowthManager.SwapSelected() to retry.")
      end
    end
    return false
  end

  return true
end

-- ---------------------------------------------------------------
function GrowthManager.TagSelected(raceKey)
  local playerObj = getPlayerInterface() or player
  local hand = playerObj.selectedCharacter
  if not hand then print("[GrowthManager] no selected character") return end
  local Character = hand:getCharacter()
  if not Character then print("[GrowthManager] no character") return end

  local cfg = growthConfig[raceKey]
  if not cfg then print("[GrowthManager] no config for " .. tostring(raceKey)) return end

  local AppDataBase = Character:getAppearance()
  local fdata = AppDataBase.appearanceData.fdata
  local sdata = AppDataBase.appearanceData.sdata
  local bdata = AppDataBase.appearanceData.bdata

  if sdata.GrowthRaceKey then
    print("[GrowthManager] " .. tostring(Character:getName())
      .. " is already tagged as " .. tostring(sdata.GrowthRaceKey)
      .. "; skipping.")
    return
  end

  sdata.GrowthRaceKey = raceKey
  fdata.GrowthBirthDay = GetCurrentTime()
  fdata.GrowthLastCheckedDay = -1
  bdata.GrowthMature = nil

  local rolls = {}
  for _, slider in ipairs(cfg.sliders) do
    if SliderAppliesTo(slider, Character) then
      WarnIfSliderMissing(Character, fdata, slider)
      fdata["GrowthTarget_" .. slider.name] = RollTarget(slider, cfg, rolls)
      fdata["GrowthStart_" .. slider.name] = fdata[slider.name] or slider.from
    end
  end

  AppDataBase.updatedAppearanceData = true

  print(string.format(
    "[GrowthManager] tagged %s | raceID=%s | birthDay=%.2f",
    tostring(Character:getName()),
    tostring(Character.myRace.data.stringID),
    fdata.GrowthBirthDay))
end

function GrowthManager.TagEstimated(raceKey)
  local playerObj = getPlayerInterface() or player
  local hand = playerObj.selectedCharacter
  if not hand then print("[GrowthManager] no selected character") return end
  local Character = hand:getCharacter()
  if not Character then print("[GrowthManager] no character") return end

  local currentDay = GetCurrentTime()
  TagCharacterEstimated(Character, currentDay, false)
end

function GrowthManager.UntagSelected()
  local playerObj = getPlayerInterface() or player
  local hand = playerObj.selectedCharacter
  if not hand then print("[GrowthManager] no selected character") return end
  local Character = hand:getCharacter()
  if not Character then print("[GrowthManager] no character") return end

  local AppDataBase = Character:getAppearance()
  local fdata = AppDataBase.appearanceData.fdata
  local sdata = AppDataBase.appearanceData.sdata
  local bdata = AppDataBase.appearanceData.bdata

  local RaceKey = sdata.GrowthRaceKey
  if not RaceKey then
    print("[GrowthManager] " .. tostring(Character:getName()) .. " is not tagged")
    return
  end

  local cfg = growthConfig[RaceKey]
  if cfg then
    for _, slider in ipairs(cfg.sliders) do
      fdata["GrowthStart_" .. slider.name] = nil
      fdata["GrowthTarget_" .. slider.name] = nil
    end
    ApplyStatScale(Character, cfg, 0, true)
  end
  sdata.GrowthRaceKey = nil
  fdata.GrowthBirthDay = nil
  fdata.GrowthLastCheckedDay = nil
  bdata.GrowthMature = nil
  bdata.GrowthSwapFailed = nil
  AppDataBase.updatedAppearanceData = true

  print("[GrowthManager] untagged " .. tostring(Character:getName()))
end

-- Console helper: list the selected character's fdata keys and values, optionally
-- filtered by a substring (case-insensitive), e.g. GrowthManager.DumpFdata("horn")
function GrowthManager.DumpFdata(filter)
  local playerObj = getPlayerInterface() or player
  local hand = playerObj.selectedCharacter
  local Character = hand and hand:getCharacter()
  if not Character then print("[GrowthManager] no selected character") return end

  local f = filter and string.lower(tostring(filter)) or nil
  print("[GrowthManager] fdata of " .. tostring(Character:getName())
    .. " (" .. tostring(Character.myRace.data.stringID) .. ")")
  for k, v in pairs(Character:getAppearanceData().fdata) do
    local key = tostring(k)
    if not f or string.find(string.lower(key), f, 1, true) then
      print("[GrowthManager]   " .. key .. " = " .. tostring(v))
    end
  end
end

-- Console helper: print limb max health and a few stats for the selected character.
-- Run it on a child, run GrowthManager.SwapSelected(), run it again: if limb max
-- health jumps toward the adult race's value, the swap re-derives it (then put
-- "limbs" in cfg.statRevert).
function GrowthManager.ProbeStats()
  local playerObj = getPlayerInterface() or player
  local hand = playerObj.selectedCharacter
  local Character = hand and hand:getCharacter()
  if not Character then print("[GrowthManager] no selected character") return end

  print("[GrowthManager] stats of " .. tostring(Character:getName())
    .. " (" .. tostring(Character.myRace.data.stringID) .. ")")
  for _, name in ipairs({ "strength", "toughness", "athletics", "swimming",
                          "dexterity", "perception", "meleeAttack", "katanas" }) do
    local ok, v = pcall(function() return Character.stats[name] end)
    print(string.format("[GrowthManager]   stats.%s = %s", name, ok and tostring(v) or "<error>"))
  end

  local ok, err = pcall(function()
    for k, limb in pairs(Character.medical.anatomy) do
      print(string.format("[GrowthManager]   limb %s: _maxHealth=%s flesh=%s",
        tostring(k), tostring(limb._maxHealth), tostring(limb.flesh)))
    end
  end)
  if not ok then print("[GrowthManager] limb dump failed: " .. tostring(err)) end
end

-- Manual swap for the selected character, using the config entry of its
-- CURRENT (child) race. Use it to retry a failed swap, or for characters that
-- were marked mature before the swap existed. Only works on a child race that
-- has an entry in growth_config.lua.
function GrowthManager.SwapSelected()
  local playerObj = getPlayerInterface() or player
  local hand = playerObj.selectedCharacter
  if not hand then print("[GrowthManager] no selected character") return end
  local Character = hand:getCharacter()
  if not Character then print("[GrowthManager] no character") return end

  local raceID = Character.myRace and Character.myRace.data
    and Character.myRace.data.stringID
  local cfg = raceID and growthConfig[raceID]
  if not cfg or not cfg.adultRaceName then
    print("[GrowthManager] no swap config for race " .. tostring(raceID))
    return
  end

  -- A tagged (still growing) child: cancel tracking first, which reverts the stat ramp.
  -- Otherwise the race-mismatch handler would undo the ramp again after the swap.
  if Character:getAppearance().appearanceData.sdata.GrowthRaceKey then
    GrowthManager.UntagSelected()
  end

  local bdata = Character:getAppearance().appearanceData.bdata
  bdata.GrowthSwapFailed = nil
  if not SwapToAdultRace(Character, cfg) then
    bdata.GrowthSwapFailed = true
  end
end

-- ---------------------------------------------------------------
local function OnCharacterSelect(hand)
  if not hand then return end
  local Character
  if type(hand.getCharacter) == "function" then
    Character = hand:getCharacter()
  else
    Character = hand
  end
  if not Character then return end
  if not Character:isHuman() then return end

  local AppDataBase = Character:getAppearance()
  if not AppDataBase or not AppDataBase.appearanceData then return end
  local fdata = AppDataBase.appearanceData.fdata
  local sdata = AppDataBase.appearanceData.sdata
  local bdata = AppDataBase.appearanceData.bdata

  if sdata.GrowthRaceKey then return end
  if bdata.GrowthMature then return end

  local raceID = Character.myRace.data.stringID
  local cfg = raceID and growthConfig[raceID]
  if not cfg then return end

  local t0 = EstimateGrowthFraction(Character, cfg)
  if t0 == nil then
    print("[GrowthManager] untracked child " .. tostring(Character:getName())
      .. " (no slider data to estimate from)")
    return
  end

  local effectiveDays = GetEffectiveGrowthDays(Character, cfg)
  local override = GetOverride(Character)
  local note = ""
  if override and type(override.growthTimeMultiplier) == "number" then
    note = string.format(" [multiplier %.2f -> %.0f days]",
      override.growthTimeMultiplier, effectiveDays)
  end

  print(string.format(
    "[GrowthManager] untracked child: %s | raceID=%s | estimated growth %.0f%%%s | run GrowthManager.TagEstimated(\"%s\")",
    tostring(Character:getName()), tostring(raceID),
    t0 * 100, note, tostring(raceID)))
end

registerHandler("onCharacterSelect", OnCharacterSelect)

-- ---------------------------------------------------------------
local counter = 0

local function UpdateCharacters()
  counter = counter + 1
  if counter < 40 then return end
  counter = 0

  local playerObj = getPlayerInterface() or player
  local PlayerCharacters = playerObj:getAllPlayerCharacters()
  local currentDay = GetCurrentTime()

  for i, Character in pairs(PlayerCharacters) do
    if Character:isHuman() then
      local AppDataBase = Character:getAppearance()
      if AppDataBase and AppDataBase.appearanceData then
        local sdata = AppDataBase.appearanceData.sdata
        local bdata = AppDataBase.appearanceData.bdata

        if sdata.GrowthRaceKey then
          GrowCharacter(Character)
        elseif not bdata.GrowthMature then
          TagCharacterEstimated(Character, currentDay, false)
        else
          MaybeSwapMature(Character)
        end
      end
    end
  end
end

registerHandler("onCharsUpdate", UpdateCharacters)

_G.GrowthManager = GrowthManager
return GrowthManager
