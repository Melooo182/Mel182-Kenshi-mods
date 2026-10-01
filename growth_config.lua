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

return growthConfig