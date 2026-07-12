.pragma library

// ─────────────────────────────────────────────────────────────────────────
// Life-OS state machine: a HEXACO personality model rendered as a
// psychologically-safe RPG progression engine. Pure functions over a plain
// state object — no QML/UI here, so it's unit-testable with node (see the
// standalone tests) and the UI layer just reads its outputs.
//
// Guardrails baked in (all from the design brief):
//   • Focus Points (FP): a PERSISTENT 0-1000 behavioural score that doubles as
//     the protective buffer. Negative deltas drain FP FIRST; permanent XP is
//     only ever threatened by the OVERFLOW past a fully drained FP. Unlike the
//     old daily-renewable Willpower Shield it does NOT refill overnight — you
//     rebuild it by doing hard good things and by REPAIRING what you broke. So
//     a good run literally buys you resilience, and a bad run leaves you thin.
//   • Single-Point Decay: that overflow is NOT applied instantly — it lands in
//     a per-facet `pendingDecay` ledger and only compiles into real XP loss at
//     a scheduled check-in (runCheckIn), so a bad moment never instantly
//     de-ranks you in real time.
//   • Rest Mode (Tavern Protocol): when isRestModeActive, the whole engine
//     freezes — no drains, no penalties, no XP gain, no decay compilation.
//   • Reframing over Regression: a drop in one facet passes a fraction of that
//     drop to a complementary facet as a bonus (a "re-spec", not a raw loss).
//   • sqrt leveling: Level = K*sqrt(XP), so higher levels are a long grind.
// ─────────────────────────────────────────────────────────────────────────

// ── HEXACO structure (HEXACO-PI-R): 6 dimensions × 4 facets = 24 ───────────
var DIMENSIONS = [
    { key: "H", name: "Honesty-Humility", glyph: "", facets: [
        { key: "sincerity",        name: "Sincerity" },
        { key: "fairness",         name: "Fairness" },
        { key: "greed_avoidance",  name: "Greed Avoidance" },
        { key: "modesty",          name: "Modesty" } ] },
    { key: "E", name: "Emotionality", glyph: "", facets: [
        { key: "fearfulness",      name: "Fearfulness" },
        { key: "anxiety",          name: "Anxiety" },
        { key: "dependence",       name: "Dependence" },
        { key: "sentimentality",   name: "Sentimentality" } ] },
    { key: "X", name: "Extraversion", glyph: "", facets: [
        { key: "social_self_esteem", name: "Social Self-Esteem" },
        { key: "social_boldness",    name: "Social Boldness" },
        { key: "sociability",        name: "Sociability" },
        { key: "liveliness",         name: "Liveliness" } ] },
    { key: "A", name: "Agreeableness", glyph: "", facets: [
        { key: "forgiveness",      name: "Forgiveness" },
        { key: "gentleness",       name: "Gentleness" },
        { key: "flexibility",      name: "Flexibility" },
        { key: "patience",         name: "Patience" } ] },
    { key: "C", name: "Conscientiousness", glyph: "", facets: [
        { key: "organization",     name: "Organization" },
        { key: "diligence",        name: "Diligence" },
        { key: "perfectionism",    name: "Perfectionism" },
        { key: "prudence",         name: "Prudence" } ] },
    { key: "O", name: "Openness", glyph: "", facets: [
        { key: "aesthetic_appreciation", name: "Aesthetic Appreciation" },
        { key: "inquisitiveness",        name: "Inquisitiveness" },
        { key: "creativity",             name: "Creativity" },
        { key: "unconventionality",      name: "Unconventionality" } ] }
];

function allFacetKeys() {
    var keys = [];
    for (var i = 0; i < DIMENSIONS.length; i++)
        for (var j = 0; j < DIMENSIONS[i].facets.length; j++)
            keys.push(DIMENSIONS[i].facets[j].key);
    return keys;
}

function facetName(key) {
    for (var i = 0; i < DIMENSIONS.length; i++)
        for (var j = 0; j < DIMENSIONS[i].facets.length; j++)
            if (DIMENSIONS[i].facets[j].key === key) return DIMENSIONS[i].facets[j].name;
    return key;
}

function dimensionOf(facetKey) {
    for (var i = 0; i < DIMENSIONS.length; i++)
        for (var j = 0; j < DIMENSIONS[i].facets.length; j++)
            if (DIMENSIONS[i].facets[j].key === facetKey) return DIMENSIONS[i].key;
    return null;
}

// ── Reframing table: when SOURCE facet drops, TARGET facet gains a fraction ─
// Thematically, each pair is a "specialization" — pulling back on one mode of
// being feeds a complementary one (the classic "deep focus lowered my
// Sociability but raised my Diligence" trade).
var RESPEC_RATIO = 0.5;
var REFRAME = {
    sociability:        "diligence",
    liveliness:         "prudence",
    social_boldness:    "modesty",
    social_self_esteem: "sincerity",
    flexibility:        "organization",
    unconventionality:  "prudence",
    inquisitiveness:    "perfectionism",
    forgiveness:        "fairness",
    gentleness:         "diligence",
    dependence:         "social_self_esteem",
    // and the reverse specializations
    diligence:          "liveliness",
    perfectionism:      "flexibility",
    organization:       "creativity",
    prudence:           "unconventionality",
    modesty:            "social_boldness"
};

// ── Behavior → facet routing (the "objective input" layer) ─────────────────
// The between-session realities a therapist actually tracks — avoidance
// mapping, conflict/rupture logs, negative self-talk, executive-function
// friction, and the altruism/isolation balance — are NOT stored as their own
// traits. They are INPUTS that nudge specific HEXACO facets. logBehavior()
// turns a named signal + intensity into applyEvent() calls, so a real tracking
// layer routes straight into the same shielded, deferred-decay pipeline as
// everything else (a bad stretch still drains FOCUS POINTS first, never instant
// permanent loss). This is where "altruism feeds the personality part" is made
// literal — mapped to the facets it actually expresses through.
var BEHAVIOR_MAP = {
    // Micro-behavioral (avoidance mapping, rupture logs, self-talk tally)
    avoidance:              [ { facet: "diligence", sign: -1 }, { facet: "prudence", sign: -1 } ],
    rupture_unrepaired:     [ { facet: "patience", sign: -1 }, { facet: "forgiveness", sign: -1 } ],
    rupture_repaired:       [ { facet: "forgiveness", sign: +1 }, { facet: "flexibility", sign: +1 } ],
    negative_self_talk:     [ { facet: "social_self_esteem", sign: -1 } ],
    // Functional / executive-function friction points
    exec_friction:          [ { facet: "organization", sign: -1 }, { facet: "diligence", sign: -1 } ],
    exec_win:               [ { facet: "organization", sign: +1 }, { facet: "diligence", sign: +1 } ],
    // Altruism / isolation balance
    meaningful_social:      [ { facet: "sociability", sign: +1 }, { facet: "social_self_esteem", sign: +1 } ],
    isolation:              [ { facet: "sociability", sign: -1 } ],
    genuine_altruism:       [ { facet: "gentleness", sign: +1 }, { facet: "sincerity", sign: +1 } ],
    people_pleasing:        [ { facet: "flexibility", sign: +1 }, { facet: "modesty", sign: -1 } ],
    self_directed_boundary: [ { facet: "prudence", sign: +1 }, { facet: "social_self_esteem", sign: +1 } ],
    // ── REPAIRS: the direct antidote to each bad pattern above. These are the
    // biggest FP earners, because turning a slip around is harder than never
    // slipping — and it's the behaviour most worth reinforcing.
    avoidance_broken:       [ { facet: "diligence", sign: +1 }, { facet: "prudence", sign: +1 } ],   // did the thing you were dodging
    self_compassion:        [ { facet: "social_self_esteem", sign: +1 } ],                            // caught the self-talk and turned it
    exec_recovered:         [ { facet: "organization", sign: +1 }, { facet: "diligence", sign: +1 } ],// re-entered a task you'd bounced off
    reached_out:            [ { facet: "sociability", sign: +1 }, { facet: "social_boldness", sign: +1 } ] // broke an isolation streak
};

// ── FOCUS POINTS (FP) ──────────────────────────────────────────────────────
// A persistent 0-1000 score, NOT a daily-renewable meter. It is simultaneously:
//   • the LEDGER of how you've been behaving, and
//   • the BUFFER that protects permanent XP from a bad stretch.
// Bad behaviour drains it (via the shield path in applyEvent — magnitude-scaled,
// so a 2-facet rupture costs more than a 1-facet slip). Hard good behaviour and
// REPAIRS refill it, per the table below.
// Scale is 0-400. GAINS are scaled to that range (0.4× the original draft), but
// the DRAIN TICK stays at 20 FP per point of facet damage — deliberately NOT
// scaled down. On a 400-point bar that means bad behaviour bites 2.5× harder
// relative to the scale than good behaviour heals: a single 2-facet rupture at
// intensity 3 costs 120 FP (30% of the whole bar), while the best repair pays
// ~16. Losing focus is fast; earning it back is slow. That asymmetry is the
// point of the system.
var FP_MAX = 400;
var FP_PER_POINT = 20;      // FP drained per point of negative facet delta
var FP_IDLE_DECAY = 2;      // FP lost on a day where you earned none ("use it or lose it")
var REACTIVITY_FP_TAX = 12; // FP/day lost at reactivity 1.0 — regulating against
                            // other people's weather is paid for out of focus

// What a positive signal is WORTH. "hard" = costly in the moment, "repair" =
// fixing something you broke (weighted highest by design).
var FP_GAINS = {
    rupture_repaired:       { fp: 16, kind: "repair" },
    avoidance_broken:       { fp: 14, kind: "repair" },
    self_directed_boundary: { fp: 14, kind: "hard"   },
    exec_recovered:         { fp: 12, kind: "repair" },
    genuine_altruism:       { fp: 12, kind: "hard"   },
    exec_win:               { fp: 10, kind: "hard"   },
    self_compassion:        { fp:  8, kind: "repair" },
    reached_out:            { fp:  8, kind: "repair" },
    meaningful_social:      { fp:  6, kind: "good"   }
};

// Gains get harder the higher you already are — no grinding to 1000 on easy
// wins. Full value at FP 0, 35% value at FP 1000.
function fpGainScale(fp) { return 0.35 + 0.65 * (1 - clamp(fp / FP_MAX, 0, 1)); }

function fpLabel(fp) {
    if (fp < 60)  return "Broken";
    if (fp < 140) return "Slipping";
    if (fp < 240) return "Steady";
    if (fp < 340) return "Sharp";
    return "Locked in";
}

// Award FP for a positive signal (returns what was actually granted).
function awardFp(state, signalKey, intensity) {
    if (state.isRestModeActive) return 0;
    var g = FP_GAINS[signalKey];
    if (!g) return 0;
    var mag = Math.abs(intensity === undefined || intensity === null ? 1 : intensity);
    var granted = Math.round(g.fp * mag * fpGainScale(state.vitals.fp));
    state.vitals.fp = clamp(state.vitals.fp + granted, 0, FP_MAX);
    state.fpEarnedToday = (state.fpEarnedToday || 0) + granted;
    return granted;
}

// ── Danger zones: named maladaptive extremes, checked against facet SCORES ──
// (score is 0-100 "current expression", distinct from permanent XP/Level).
// Each predicate returns true when the pattern is active.
var DANGER_ZONES = [
    { key: "hubris_blindness", dim: "H", name: "Hubris Blindness",
      desc: "Low modesty + low fairness — self-assessment blind spot; over-claiming credit.",
      test: function (sc) { return sc.modesty < 22 && sc.fairness < 32; } },
    { key: "anxiety_spiral", dim: "E", name: "Anxiety Spiral",
      desc: "Anxiety running very high — worry compounding faster than it resolves.",
      test: function (sc) { return sc.anxiety > 82; } },
    { key: "brittle_dependence", dim: "E", name: "Brittle Dependence",
      desc: "High dependence + high fearfulness — reassurance-seeking loop.",
      test: function (sc) { return sc.dependence > 82 && sc.fearfulness > 70; } },
    { key: "social_withdrawal", dim: "X", name: "Social Withdrawal",
      desc: "Sociability + social self-esteem both bottomed out — isolation risk.",
      test: function (sc) { return sc.sociability < 18 && sc.social_self_esteem < 28; } },
    { key: "over_yielding", dim: "A", name: "Over-Yielding",
      desc: "Flexibility + forgiveness both maxed — boundaries dissolving (doormat mode).",
      test: function (sc) { return sc.flexibility > 88 && sc.forgiveness > 88; } },
    { key: "callousness", dim: "A", name: "Callousness",
      desc: "Gentleness + sentimentality both very low — warmth offline.",
      test: function (sc) { return sc.gentleness < 20 && sc.sentimentality < 20; } },
    { key: "analysis_paralysis", dim: "C", name: "Analysis Paralysis",
      desc: "Perfectionism sky-high + inquisitiveness high — endless refinement, no ship.",
      test: function (sc) { return sc.perfectionism > 84 && sc.inquisitiveness > 70; } },
    { key: "rigidity", dim: "C", name: "Rigidity",
      desc: "Perfectionism high + flexibility very low — brittle, change-averse.",
      test: function (sc) { return sc.perfectionism > 84 && sc.flexibility < 22; } },
    { key: "stagnation", dim: "O", name: "Stagnation",
      desc: "Inquisitiveness + creativity both very low — curiosity dormant.",
      test: function (sc) { return sc.inquisitiveness < 18 && sc.creativity < 18; } }
];

// ── Leveling (Level = K*sqrt(XP)) ──────────────────────────────────────────
var LEVEL_K = 0.35;
var XP_PER_POINT = 8;   // one "point" of behavior delta = this much permanent XP

function levelForXp(xp) { return xp > 0 ? Math.max(1, Math.floor(LEVEL_K * Math.sqrt(xp))) : 0; }
function xpFloorForLevel(lvl) { return Math.pow(lvl / LEVEL_K, 2); }
function levelProgress(xp) {
    var lvl = levelForXp(xp);
    if (lvl <= 0) return 0;
    var cur = xpFloorForLevel(lvl), next = xpFloorForLevel(lvl + 1);
    if (next <= cur) return 1;
    return Math.max(0, Math.min(1, (xp - cur) / (next - cur)));
}
function nextLevelXp(xp) { return Math.ceil(xpFloorForLevel(levelForXp(xp) + 1)); }

function clamp(v, lo, hi) { return v < lo ? lo : (v > hi ? hi : v); }

// ── User profile → daily calorie target (drives hpMax) ─────────────────────
// EDIT THESE to your real numbers — everything downstream recomputes.
// `activity` is your NON-exercise lifestyle baseline (job, chores); tracked
// exercise (steps + active minutes) is added on top per-day, so a workout day
// genuinely raises that day's target instead of being averaged into a static
// multiplier — and there's no double counting.
var USER_PROFILE = {
    age:      25,          // years
    weightKg: 75,          // kg
    heightCm: 178,         // cm
    sex:      "male",      // "male" | "female" (Mifflin-St Jeor constant)
    activity: "sedentary", // sedentary | light | moderate | very | extreme  (baseline, EXCLUDING workouts)
    goal:     "maintain",  // "cut" (−500) | "maintain" | "bulk" (+300)
    // TRUE max heart rate, in bpm, from a real max-effort test (ramp to failure,
    // or the highest bpm you've ever actually seen). Leave null and the Zone-2
    // band is derived from your AGE instead — a population estimate that is right
    // on average but ±10–12 bpm for any individual. Fill this in and the band
    // stops being a guess.
    hrMaxMeasured: null
};
var ACTIVITY_FACTORS = { sedentary: 1.2, light: 1.375, moderate: 1.55, very: 1.725, extreme: 1.9 };
var GOAL_DELTA = { cut: -500, maintain: 0, bulk: 300 };
var CALORIE_FLOOR = 1200;   // never target below this, whatever the math says

// Mifflin-St Jeor resting metabolic rate.
function bmr(p) {
    return 10 * p.weightKg + 6.25 * p.heightCm - 5 * p.age + (p.sex === "female" ? -161 : 5);
}
// Rough kcal from today's tracked movement: ~0.04 kcal/step (walking) plus
// ~6 kcal per dedicated active minute. Approximations, but they move the
// target in the right direction on training days.
function exerciseCalories(state) {
    var m = state.trackers.movement;
    return Math.round(m.steps * 0.04 + m.activeMin * 6);
}
// The calorie budget for TODAY: baseline TDEE + today's tracked exercise,
// shifted by the goal. This is what hpMax becomes.
function dailyCalorieTarget(state) {
    var p = USER_PROFILE;
    var base = bmr(p) * (ACTIVITY_FACTORS[p.activity] || 1.2);
    return Math.max(CALORIE_FLOOR, Math.round(base + exerciseCalories(state) + (GOAL_DELTA[p.goal] || 0)));
}

// ── Macro split (protein / fat / carbs), evidence-based ────────────────────
// PROTEIN first, by bodyweight (the strongest lever; higher on a cut to spare
// muscle in a deficit): 2.2 g/kg cut, 1.8 maintain, 2.0 bulk (within the
// 1.6–2.2 g/kg range the literature supports for active people).
// FAT as a % of calories, with a ~0.6 g/kg hormonal-health floor: 25% cut/bulk,
// 30% maintain. CARBS fill the remainder — the training fuel, so they scale up
// on a bulk and down on a cut automatically.
var MACRO_PLAN = {
    cut:      { proteinPerKg: 2.2, fatPct: 0.25 },
    maintain: { proteinPerKg: 1.8, fatPct: 0.30 },
    bulk:     { proteinPerKg: 2.0, fatPct: 0.25 }
};
var FAT_FLOOR_PER_KG = 0.6;   // minimum fat for hormones, whatever the % says

// The three components the calorie TARGET is built from (for the segment bars
// under the gauge): base TDEE, today's exercise, and the goal bonus (bulk +300).
function calorieSegments(state) {
    var p = USER_PROFILE;
    var base = Math.round(bmr(p) * (ACTIVITY_FACTORS[p.activity] || 1.2));
    var exercise = exerciseCalories(state);
    var goal = GOAL_DELTA[p.goal] || 0;               // +300 bulk, −500 cut, 0 maintain
    return { base: base, exercise: exercise, goal: goal,
             goalLabel: p.goal === "bulk" ? "Bulk" : p.goal === "cut" ? "Cut" : "",
             target: dailyCalorieTarget(state) };
}

// Segments that build a gauge's TARGET, for the little marker-bars under the
// big bar. HP: base TDEE + exercise + bulk bonus. PP: base + exercise + heat.
// Each seg = { label, amount } in the gauge's units; they sum to (≈) target.
function gaugeSegments(state, key) {
    if (key === "hp") {
        var c = calorieSegments(state);
        var segs = [ { label: "Base", amount: c.base }, { label: "Exercise", amount: c.exercise } ];
        if (c.goal > 0) segs.push({ label: "Bulk", amount: c.goal });
        return { segs: segs, target: c.target };
    }
    if (key === "pp") {
        var base = Math.round(33 * USER_PROFILE.weightKg);
        return { segs: [ { label: "Base", amount: base },
                         { label: "Exercise", amount: exerciseWaterMl(state) },
                         { label: "Heat", amount: heatBonusMl(state) } ],
                 target: dailyWaterTarget(state) };
    }
    return null;
}

// Macro targets + what's been consumed today, for the pie/ring.
function macroReport(state) {
    var m = dailyMacros(state), n = state.trackers.nutrition;
    return {
        target:   { protein: m.protein, carb: m.carb, fat: m.fat,
                    proteinPct: m.proteinPct, carbPct: m.carbPct, fatPct: m.fatPct },
        consumed: { protein: n.protein || 0, carb: n.carbs || 0, fat: n.fat || 0 }
    };
}

function dailyMacros(state) {
    var p = USER_PROFILE;
    var plan = MACRO_PLAN[p.goal] || MACRO_PLAN.maintain;
    var kcal = dailyCalorieTarget(state);

    var proteinG = Math.round(plan.proteinPerKg * p.weightKg);
    var proteinKcal = proteinG * 4;

    var fatKcal = kcal * plan.fatPct;
    var fatG = Math.round(fatKcal / 9);
    var fatFloorG = Math.round(FAT_FLOOR_PER_KG * p.weightKg);
    if (fatG < fatFloorG) { fatG = fatFloorG; fatKcal = fatG * 9; }

    var carbKcal = Math.max(0, kcal - proteinKcal - fatKcal);
    var carbG = Math.round(carbKcal / 4);

    return {
        kcal: kcal,
        protein: proteinG, fat: fatG, carb: carbG,
        proteinPct: Math.round(proteinKcal / kcal * 100),
        fatPct: Math.round(fatKcal / kcal * 100),
        carbPct: Math.round(carbKcal / kcal * 100),
        proteinPerKg: plan.proteinPerKg
    };
}

// ── Daily water target (drives ppMax, all in ml) ───────────────────────────
// baseline 33 ml/kg  +  ~12 ml per active minute (sweat replacement)
// + heat: +50 ml per °C of today's high above 25°C (×1.3 when humid >60%)
// + diuretics from the dependencies tracker: 150 ml per alcoholic drink, and
//   0.5 ml per mg of caffeine beyond 300 mg (doses are logged as 150 mg each).
var CAFFEINE_MG_PER_DOSE = 150;   // the user's habitual dose size, for display
function depCount(state, name) {
    var d = state.trackers.dependencies;
    for (var i = 0; i < d.length; i++) if (d[i].name === name) return d[i].count;
    return 0;
}
function heatBonusMl(state) {
    var e = state.trackers.environment;
    if (e.tempC <= 25) return 0;
    var bonus = (e.tempC - 25) * 50;
    if (e.humidity > 60) bonus *= 1.3;
    return Math.round(bonus);
}
function exerciseWaterMl(state) { return Math.round(state.trackers.movement.activeMin * 12); }
// Diuretic load = the COMPOUNDS you drank (see COMPOUNDS, below): ethanol's flat
// per-unit cost + caffeine's, but only past habituation.
function diureticWaterMl(state) {
    return ethanolDiuresisMl(state) + caffeineDiuresisMl(state);
}
function dailyWaterTarget(state) {
    var base = 33 * USER_PROFILE.weightKg;
    var ml = base
           + exerciseWaterMl(state)
           + heatBonusMl(state)
           + diureticWaterMl(state)
           - electrolyteSavingMl(state, base);   // the one compound that HELPS
    return Math.round(ml / 10) * 10;
}

// ── POTION EFFECTS: the ACTIVE COMPOUNDS, not the drinks ───────────────────
// A drink is just a delivery vehicle. What actually acts on you is the water
// plus whatever pharmacology rides along in it. So the effect model lives at
// the COMPOUND level — add a new drink and its behaviour falls out of its
// composition automatically, with no new rules to write.
//
//   WATER        the base. Fills PP.
//   CAFFEINE     mg. Adenosine antagonist: arousal ↑ (MP), sleep latency ↑.
//                Half-life ~5.5 h, so timing matters as much as dose.
//                Mildly diuretic, but ONLY past a habituated ~300 mg/day.
//   ETHANOL      standard units (1 unit ≈ 14 g). Suppresses ADH → a hard
//                ~150 ml diuretic cost each, so a drink can be NET NEGATIVE
//                hydration. Suppresses REM → wrecks sleep ARCHITECTURE even
//                when total sleep time looks fine. 7 kcal/g.
//   SUGAR        g. 4 kcal/g → HP. Spike-and-crash hits energy after ~90 min.
//   ELECTROLYTES mg sodium. The only compound that IMPROVES retention: water
//                with sodium is held rather than urinated straight out.
var COMPOUNDS = {
    caffeine: {
        name: "Caffeine", unit: "mg", halfLifeH: 5.5,
        habituationMg: 300,          // diuresis only past this daily intake
        diuresisMlPerMg: 0.5,        // …and only on the excess
        arousalPerMg: 1 / 400,       // 400 mg ⇒ +1.0 arousal (the cap)
        effect: "Arousal ↑ · sleep latency ↑ · mildly diuretic past 300mg"
    },
    ethanol: {
        name: "Ethanol", unit: "units", gPerUnit: 14,
        diuresisMlPerUnit: 150,      // ADH suppression — the big one
        kcalPerG: 7,
        remSuppressionPerUnit: 0.08, // fraction of REM lost per unit (advisory)
        effect: "−150ml water each · REM suppressed · 7 kcal/g"
    },
    sugar: {
        name: "Sugar", unit: "g", kcalPerG: 4,
        effect: "4 kcal/g → HP · spike then crash"
    },
    electrolytes: {
        name: "Electrolytes", unit: "mg Na",
        retentionPerMg: 0.0004,      // ~+40% retention at ~1000 mg sodium
        effect: "Improves fluid RETENTION — the only compound that helps"
    }
};

// Today's compound intake, in one place. Every drink resolves into these.
function emptyIntake() {
    return { waterMl: 0, caffeineMg: 0, ethanolUnits: 0, sugarG: 0,
             sodiumMg: 0, potassiumMg: 0, magnesiumMg: 0 };
}

// ── The compounds' actual effects ──────────────────────────────────────────
// Caffeine: diuretic only on the excess past habituation.
function caffeineDiuresisMl(state) {
    var c = COMPOUNDS.caffeine;
    var mg = state.trackers.intake.caffeineMg;
    return Math.round(Math.max(0, mg - c.habituationMg) * c.diuresisMlPerMg);
}
// Ethanol: a flat, unforgiving water cost per unit.
function ethanolDiuresisMl(state) {
    return Math.round(state.trackers.intake.ethanolUnits * COMPOUNDS.ethanol.diuresisMlPerUnit);
}
// Electrolytes: the one compound that REDUCES your water need, by helping you
// keep what you drink instead of passing it straight through.
function electrolyteSavingMl(state, baseNeedMl) {
    var e = COMPOUNDS.electrolytes;
    var retention = clamp(state.trackers.intake.sodiumMg * e.retentionPerMg, 0, 0.15);
    return Math.round(baseNeedMl * retention);
}
// Caffeine still circulating right now, from dose + elapsed time (exponential
// decay at the real half-life). This is what actually drives arousal — 200 mg
// at 08:00 is a different animal from 200 mg at 20:00.
function activeCaffeineMg(state, hoursSinceDose) {
    var h = hoursSinceDose === undefined ? 0 : hoursSinceDose;
    return state.trackers.intake.caffeineMg * Math.pow(0.5, h / COMPOUNDS.caffeine.halfLifeH);
}
// Caffeine curfew: the hour after which a dose is still meaningfully aboard at
// lights-out. Two half-lives ⇒ ~25% remaining.
function caffeineCurfewHour(bedtimeHour) {
    var bed = bedtimeHour === undefined ? 23 : bedtimeHour;
    return bed - 2 * COMPOUNDS.caffeine.halfLifeH;
}
// Ethanol's cost to sleep ARCHITECTURE (not duration) — advisory: a drink
// cannot retroactively change last night, so this is a forecast for TONIGHT,
// never silently applied to EP.
function ethanolRemPenalty(state) {
    return clamp(state.trackers.intake.ethanolUnits * COMPOUNDS.ethanol.remSuppressionPerUnit, 0, 0.5);
}
// How many of today's calories arrived in a GLASS rather than on a plate.
// These are already inside nutrition.calories (drink() folds them in) — this is
// purely for the breakdown, so liquid calories can't hide.
function drinkCalories(state) {
    return Math.round(state.trackers.nutrition.drinkCalories || 0);
}

// ── Logging a drink: give it a COMPOSITION, not a name ─────────────────────
// drink(state, { ml, caffeineMg, ethanolUnits, sugarG, electrolyteMg })
// A few presets exist purely as shorthand — they are just compositions, and
// carry no special rules of their own.
var DRINK_PRESETS = {
    water:        { ml: 250 },
    sparkling:    { ml: 250 },
    coffee:       { ml: 240, caffeineMg: 95 },
    espresso:     { ml: 30,  caffeineMg: 65 },
    tea:          { ml: 240, caffeineMg: 47 },
    herbal_tea:   { ml: 240 },
    energy_drink: { ml: 250, caffeineMg: 160, sugarG: 27 },
    soda:         { ml: 330, caffeineMg: 34,  sugarG: 35 },
    juice:        { ml: 250, sugarG: 24 },
    sports_drink: { ml: 500, sugarG: 20, sodiumMg: 460, potassiumMg: 120 },
    beer:         { ml: 350, ethanolUnits: 1, sugarG: 3 },
    wine:         { ml: 150, ethanolUnits: 1.6 },
    spirits:      { ml: 45,  ethanolUnits: 1 }
};

function drink(state, composition, count) {
    if (!composition) return null;
    var c = typeof composition === "string" ? DRINK_PRESETS[composition] : composition;
    if (!c) return null;
    var n = count === undefined || count === null ? 1 : count;
    var i = state.trackers.intake;
    var sugarG   = (c.sugarG       || 0) * n;
    var ethanolU = (c.ethanolUnits || 0) * n;

    i.waterMl      += (c.ml            || 0) * n;
    i.caffeineMg   += (c.caffeineMg    || 0) * n;
    i.ethanolUnits += ethanolU;
    i.sugarG       += sugarG;
    i.sodiumMg     += (c.sodiumMg      || 0) * n;
    i.potassiumMg  += (c.potassiumMg   || 0) * n;
    i.magnesiumMg  += (c.magnesiumMg   || 0) * n;

    // LIQUID CALORIES ARE CALORIES. Sugar (4 kcal/g) and ethanol (7 kcal/g) go
    // straight into the same food counter a meal does — they spend the exact
    // same daily budget, so they belong in the same number rather than in a
    // separate "drinks" bucket that's easy to not look at.
    var kcal = Math.round(sugarG   * COMPOUNDS.sugar.kcalPerG
                        + ethanolU * COMPOUNDS.ethanol.gPerUnit * COMPOUNDS.ethanol.kcalPerG);
    state.trackers.nutrition.calories    += kcal;
    state.trackers.nutrition.drinkCalories = (state.trackers.nutrition.drinkCalories || 0) + kcal;

    syncVitalsFromTrackers(state);
    return { intake: i, kcal: kcal };
}

// A compound's live contribution line, for the PP detail page.
function compoundLines(state) {
    var i = state.trackers.intake, out = [];
    if (i.caffeineMg > 0)
        out.push({ name: "Caffeine", amount: Math.round(i.caffeineMg) + " mg",
                   effect: caffeineDiuresisMl(state) > 0
                       ? "arousal ↑ · −" + caffeineDiuresisMl(state) + " ml"
                       : "arousal ↑ · no water cost yet" });
    if (i.ethanolUnits > 0)
        out.push({ name: "Ethanol", amount: (Math.round(i.ethanolUnits * 10) / 10) + " units",
                   effect: "−" + ethanolDiuresisMl(state) + " ml · REM −" + Math.round(ethanolRemPenalty(state) * 100) + "%" });
    if (i.sugarG > 0)
        out.push({ name: "Sugar", amount: Math.round(i.sugarG) + " g",
                   effect: "+" + Math.round(i.sugarG * COMPOUNDS.sugar.kcalPerG) + " kcal → HP" });
    if (i.sodiumMg > 0)
        out.push({ name: "Electrolytes", amount: Math.round(i.sodiumMg) + " mg Na",
                   effect: "retention ↑ · need −" + electrolyteSavingMl(state, 33 * USER_PROFILE.weightKg) + " ml" });
    return out;
}

// ── POTIONS ────────────────────────────────────────────────────────────────
// Everything you INGEST that has an effect — stimulants, alcohol, sugar, and
// medications (ibuprofen, NyQuil, …) — renders as a pixel-art potion on the PP
// page with its BUFFS (what it gives you) and DEBUFFS (what it costs you).
//
// ADDING A NEW POTION — append one entry to POTION_DEFS. Every field is data;
// no view code changes:
//
//   {
//     key:     "melatonin",        // unique id; also the meds-log key
//     name:    "Melatonin",        // shown next to the bottle
//     colour:  "mauve",            // bottle liquid: any accentColor() name —
//                                  //   red · yellow · green · teal · peach · mauve · blue
//     unit:    "mg",               // printed after the amount
//     ceiling: 5,                  // a full bottle = this much (drives the liquid level
//                                  //   AND the "over the limit" debuff)
//     amount:  medDose("melatonin"),   // how much you've had today (see below)
//     buffs:   ["Sleep onset ↑"],      // array, OR function (state, amt) → array
//     debuffs: ["Grogginess AM"]       // same
//   }
//
// `amount` is a function (state) → number. Use medDose(key) to read it from the
// meds log (trackers.meds, fed by foodlog.json's `meds` block); the built-in
// three read straight off the drink-compound trackers instead.
// `buffs` / `debuffs` may be a plain array (static) or a function (state, amt)
// when the numbers depend on the day (see caffeine/alcohol below).
// An "Over <ceiling> <unit>" debuff is appended automatically past the ceiling.

// Reads a dose out of the day's medication log.
function medDose(key) {
    return function (state) {
        var m = (state.trackers && state.trackers.meds) || {};
        return Number(m[key] || 0);
    };
}

var POTION_DEFS = [
    // ── Drink compounds (amounts come from the intake tracker) ──
    {
        key: "caffeine", name: "Caffeine", colour: "peach", unit: "mg", ceiling: 400,
        amount: function (st) { return st.trackers.intake.caffeineMg; },
        buffs: function (st, a) {
            var aro = Math.min(1, a * COMPOUNDS.caffeine.arousalPerMg);
            return ["Arousal +" + (Math.round(aro * 100) / 100), "Focus ↑"];
        },
        debuffs: function (st) {
            var out = ["Sleep latency ↑"];
            var d = caffeineDiuresisMl(st);
            if (d > 0) out.push("−" + d + " ml water");
            return out;
        }
    },
    {
        key: "alcohol", name: "Alcohol", colour: "mauve", unit: "units", ceiling: 2,
        amount: function (st) { return st.trackers.intake.ethanolUnits; },
        buffs: ["Relaxation ↑"],
        debuffs: function (st, a) {
            return ["−" + ethanolDiuresisMl(st) + " ml water",
                    "REM −" + Math.round(ethanolRemPenalty(st) * 100) + "%",
                    "+" + Math.round(a * COMPOUNDS.ethanol.gPerUnit * COMPOUNDS.ethanol.kcalPerG) + " kcal"];
        }
    },
    {
        key: "sugar", name: "Sugar", colour: "red", unit: "g", ceiling: 50,
        amount: function (st) { return st.trackers.intake.sugarG; },
        buffs: function (st, a) {
            return ["+" + Math.round(a * COMPOUNDS.sugar.kcalPerG) + " kcal → HP", "Fast energy"];
        },
        debuffs: ["Spike then crash"]
    },

    // ── Medications (amounts come from the meds log) ──
    {
        key: "ibuprofen", name: "Ibuprofen", colour: "green", unit: "mg", ceiling: 1200,
        amount: medDose("ibuprofen"),
        buffs: ["Pain ↓", "Inflammation ↓"],
        debuffs: ["Stomach lining ↓", "Kidney load ↑ — hydrate"]
    },
    {
        key: "paracetamol", name: "Paracetamol", colour: "teal", unit: "mg", ceiling: 3000,
        amount: medDose("paracetamol"),
        buffs: ["Pain ↓", "Fever ↓"],
        debuffs: ["Liver load ↑", "Don't stack with alcohol"]
    },
    {
        key: "nyquil", name: "NyQuil", colour: "blue", unit: "ml", ceiling: 30,
        amount: medDose("nyquil"),
        buffs: ["Sleep onset ↑", "Cough / congestion ↓"],
        debuffs: ["REM ↓", "Morning grogginess", "Contains alcohol"]
    },
    {
        key: "antihistamine", name: "Antihistamine", colour: "yellow", unit: "mg", ceiling: 10,
        amount: medDose("antihistamine"),
        buffs: ["Allergy ↓"],
        debuffs: ["Drowsiness ↑", "Next-day fog"]
    },
    {
        key: "melatonin", name: "Melatonin", colour: "mauve", unit: "mg", ceiling: 5,
        amount: medDose("melatonin"),
        buffs: ["Sleep onset ↑"],
        debuffs: ["Vivid dreams", "Grogginess if > 3 mg"]
    }
];

// Register a potion at runtime (same shape as a POTION_DEFS entry).
function addPotion(def) { POTION_DEFS.push(def); return POTION_DEFS.length; }

// Resolve a buffs/debuffs field that may be a static array OR a function.
function _potionLines(field, state, amt) {
    if (!field) return [];
    return (typeof field === "function") ? (field(state, amt) || []) : field.slice();
}

// Build every potion for today. `active` is false when you haven't had any —
// the view only renders the active ones.
function potionLines(state) {
    var out = [];
    for (var i = 0; i < POTION_DEFS.length; i++) {
        var p = POTION_DEFS[i];
        var amt = Number(p.amount(state) || 0);
        var active = amt > 0;
        // round to 1dp, but drop a trailing .0
        var shown = Math.round(amt * 10) / 10;
        var row = {
            key: p.key, name: p.name, colour: p.colour || "blue",
            amount: active ? shown + " " + p.unit : "none today",
            fill: clamp(amt / Math.max(1e-9, p.ceiling), 0, 1),
            active: active,
            buffs: active ? _potionLines(p.buffs, state, amt) : [],
            debuffs: active ? _potionLines(p.debuffs, state, amt) : []
        };
        if (active && amt > p.ceiling)
            row.debuffs.push("Over " + p.ceiling + " " + p.unit + " limit");
        out.push(row);
    }
    return out;
}

// ── Daily exercise targets (drive the movement tracker targets → AP) ───────
// Evidence-based, personalized by the two profile fields that actually move
// the guidelines:
//   steps — mortality-benefit plateau ≈ 9000/day under 60, 7000 at 60+
//           (2023 step-count meta-analyses); cutting adds 2000 (deficit via
//           NEAT), bulking trims 1000 (recovery > interference cardio).
//   active minutes — WHO 150–300 min/week moderate ⇒ 25/day baseline;
//           40 on a cut, 30 on a bulk.
//   workouts — 1/day tracked session (WHO strength guideline is 2+/week;
//           the daily tracker treats any deliberate session as the goal).
// Weight/height/sex intentionally DON'T alter these — guidelines are uniform;
// body size changes the calorie value of movement (handled in HP), not the
// health target.
// True once today's steps hit the profile-derived target (UI: AP bar goes gold).
function stepsGoalMet(state) {
    var m = state.trackers.movement;
    return m.steps >= m.stepTarget;
}

function dailyExerciseTargets() {
    var p = USER_PROFILE;
    var steps  = p.age >= 60 ? 7000 : 9000;
    var active = 25;
    if (p.goal === "cut")  { steps += 2000; active = 40; }
    if (p.goal === "bulk") { steps -= 1000; active = 30; }
    return { steps: steps, activeMin: active, workouts: 1 };
}

// ── ZONE 2 — what AP actually measures ─────────────────────────────────────
// AP is 60 MINUTES A DAY of Zone 2: the aerobic, conversational, fat-oxidation
// band. It's the best-evidenced dose for mitochondrial density and an aerobic
// base, and unlike "active minutes" it has a hard physiological definition — so
// the widget can say exactly what counts.
var ZONE2_TARGET_MIN = 60;

// Max heart rate. A MEASURED max (profile.hrMaxMeasured, from a real max-effort
// test) always wins. Without one we fall back to the age estimate — Tanaka (2001)
// 208 − 0.7×age, which is better calibrated than the old 220−age (that formula
// increasingly underestimates with age). Treat the estimate as a STARTING GUESS:
// it's right on average but carries a ±10–12 bpm individual spread.
function maxHr() {
    var p = USER_PROFILE;
    if (p.hrMaxMeasured) return { bpm: Math.round(p.hrMaxMeasured), measured: true };
    return { bpm: Math.round(208 - 0.7 * p.age), measured: false };
}

// The Zone-2 heart-rate band — i.e. WHAT QUALIFIES.
// Built on HEART RATE RESERVE (Karvonen) rather than a flat % of max, because HRR
// folds in your ACTUAL resting HR (which we already track from the biometrics
// feed) and lines up with the aerobic threshold far better across fitness levels:
//     HRR      = HRmax − HRrest
//     Zone 2   = 60–70% of HRR, added back onto HRrest
// As your resting HR drops with training, the band moves with you automatically.
function zone2Range(state) {
    var mx = maxHr();
    var rest = Math.round((state.trackers.biometrics && state.trackers.biometrics.rhr) || 60);
    var reserve = Math.max(1, mx.bpm - rest);
    return {
        lo:       Math.round(rest + 0.60 * reserve),
        hi:       Math.round(rest + 0.70 * reserve),
        hrMax:    mx.bpm,
        measured: mx.measured,   // false → the band is an age-based guess
        rest:     rest
    };
}

// Minutes spent in Zone 2 today.
// If the movement feed gives real HR-derived minutes (movement.zone2Min) we use
// them. Until then we fall back to the GENERAL GUESS: count logged moderate
// active minutes as zone-2-ish. `estimated` tells the UI to mark the number "~".
function zone2Today(state) {
    var m = state.trackers.movement;
    if (m.zone2Min !== undefined && m.zone2Min !== null)
        return { min: Math.max(0, m.zone2Min), estimated: false };
    return { min: Math.max(0, m.activeMin || 0), estimated: true };
}

// ── SLEEP SESSION (the hypnogram on the EP page) ───────────────────────────
// Last night as a stage-by-stage timeline, the way Apple Health draws it: four
// lanes (Awake / REM / Core / Deep) across the night, plus stage totals and the
// times you woke up.
//
//   trackers.sleep = {
//     screensOff: "22:58",                    // when your devices actually went dark
//     bedtime:    "23:42",                    // clock time you got into bed
//     segments: [ { stage: "core", min: 45 }, // IN ORDER, back-to-back, from bedtime
//                 { stage: "deep", min: 35 }, … ]
//   }
//
// Wake time is DERIVED from bedtime + the sum of the segments, so the timeline
// can never disagree with itself. The graph is drawn on a real CLOCK axis with
// hour ticks, so you can eyeball night-to-night consistency at a glance, and it
// starts at screensOff — the gap to bedtime is your WIND-DOWN.
var SLEEP_LANES = ["awake", "rem", "core", "deep"];   // top → bottom, as Apple draws it
var SLEEP_STAGES = {
    awake: { name: "Awake", colour: "peach", lane: 0 },
    rem:   { name: "REM",   colour: "teal",  lane: 1 },
    core:  { name: "Core",  colour: "blue",  lane: 2 },
    deep:  { name: "Deep",  colour: "mauve", lane: 3 }
};

function _clockToMin(s) {
    if (!s) return 0;
    var p = String(s).split(":");
    return (Number(p[0]) || 0) * 60 + (Number(p[1]) || 0);
}
function _minToClock(m) {
    m = ((Math.round(m) % 1440) + 1440) % 1440;
    var h = Math.floor(m / 60), mm = m % 60;
    return h + ":" + (mm < 10 ? "0" + mm : mm);
}
// "6h 03m" / "48m"
function fmtDur(min) {
    min = Math.max(0, Math.round(min));
    var h = Math.floor(min / 60), m = min % 60;
    return h > 0 ? (h + "h " + (m < 10 ? "0" + m : m) + "m") : (m + "m");
}

function sleepSession(state) {
    var sl = state.trackers.sleep;
    if (!sl || !sl.segments || !sl.segments.length) return null;

    var bed = _clockToMin(sl.bedtime);
    var segs = [], cursor = 0;
    var tot = { awake: 0, rem: 0, core: 0, deep: 0 };

    for (var i = 0; i < sl.segments.length; i++) {
        var g = sl.segments[i];
        var stage = SLEEP_STAGES[g.stage] ? g.stage : "core";
        var mn = Math.max(0, Number(g.min) || 0);
        segs.push({
            stage: stage, min: mn, startMin: cursor,
            lane: SLEEP_STAGES[stage].lane,
            colour: SLEEP_STAGES[stage].colour,
            clock: _minToClock(bed + cursor)
        });
        tot[stage] += mn;
        cursor += mn;
    }

    var inBed = cursor;
    var asleep = inBed - tot.awake;
    function pct(v) { return asleep > 0 ? Math.round(v / asleep * 100) : 0; }

    // A "wake-up" is an Awake block in the MIDDLE of the night — the first one is
    // just sleep latency, a trailing one is you getting up.
    var wakeTimes = [];
    for (var j = 1; j < segs.length - 1; j++)
        if (segs[j].stage === "awake") wakeTimes.push(segs[j].clock);

    // WIND-DOWN: screens-off → bedtime. The timeline starts at screens-off when we
    // have it, so the dark gap before the first sleep block is visible.
    var screens = sl.screensOff ? _clockToMin(sl.screensOff) : null;
    var windDown = 0, start = bed;
    if (screens !== null) {
        windDown = bed - screens;
        if (windDown < 0) windDown += 1440;      // screens-off was before midnight
        start = screens;
    }
    var span = windDown + inBed;

    // Hour ticks on the CLOCK axis — this is what makes consistency legible: the
    // same marks land in the same place every night.
    var ticks = [];
    for (var t = Math.ceil(start / 60) * 60; t <= start + span; t += 60)
        ticks.push({ offset: t - start, label: _minToClock(t) });

    return {
        bedtime: _minToClock(bed),
        wake:    _minToClock(bed + inBed),
        inBedMin: inBed, asleepMin: asleep,
        segments: segs,
        // clock-axis geometry (all offsets are minutes from the START of the graph)
        screensOff:  screens === null ? "" : _minToClock(screens),
        windDownMin: windDown,          // 0 when screensOff wasn't logged
        bedOffsetMin: windDown,         // where bedtime sits on the axis
        spanMin: span,                  // total width of the graph, in minutes
        ticks: ticks,
        stages: [
            { key: "deep",  name: "Deep",  min: tot.deep,  pct: pct(tot.deep),  colour: "mauve" },
            { key: "rem",   name: "REM",   min: tot.rem,   pct: pct(tot.rem),   colour: "teal"  },
            { key: "core",  name: "Core",  min: tot.core,  pct: pct(tot.core),  colour: "blue"  },
            { key: "awake", name: "Awake", min: tot.awake, pct: pct(tot.awake), colour: "peach" }
        ],
        wakeUps: wakeTimes.length,
        wakeTimes: wakeTimes
    };
}

// ── WORKOUT LOG (the Hevy-style tracker on the AP page) ────────────────────
// A session is a list of EXERCISES, each with its SETS — the same shape a
// set-tracking app logs:
//
//   {
//     name: "Push Day", minutes: 62,
//     exercises: [
//       // strength — a list of sets. `pr` flags a personal record.
//       { name: "Bench Press", sets: [ { kg: 60, reps: 10 },
//                                      { kg: 70, reps: 8 },
//                                      { kg: 75, reps: 6, pr: true } ] },
//       // cardio — no sets; distance/time/HR instead.
//       { name: "Treadmill", cardio: { minutes: 20, km: 3.4, avgHr: 143 } }
//     ]
//   }
function workoutLog(state) {
    var w = state.trackers.movement && state.trackers.movement.workoutLog;
    return Array.isArray(w) ? w : [];
}

// Volume = the classic tonnage number: Σ (weight × reps) across an exercise's sets.
function exerciseVolume(ex) {
    if (!ex || !ex.sets) return 0;
    var v = 0;
    for (var i = 0; i < ex.sets.length; i++)
        v += (Number(ex.sets[i].kg) || 0) * (Number(ex.sets[i].reps) || 0);
    return Math.round(v);
}
function sessionVolume(s) {
    var ex = (s && s.exercises) || [], v = 0;
    for (var i = 0; i < ex.length; i++) v += exerciseVolume(ex[i]);
    return v;
}
function sessionSets(s) {
    var ex = (s && s.exercises) || [], n = 0;
    for (var i = 0; i < ex.length; i++) n += (ex[i].sets ? ex[i].sets.length : 0);
    return n;
}
// The one-line summary under a session's name: "12 sets · 8,240 kg" (volume is
// dropped when the session is pure cardio and there is nothing to total).
function sessionSummary(s) {
    var sets = sessionSets(s), vol = sessionVolume(s);
    var parts = [];
    if (sets > 0) parts.push(sets + " sets");
    if (vol > 0)  parts.push(vol.toLocaleString() + " kg");
    if (s && s.minutes) parts.push(s.minutes + " min");
    return parts.join(" · ");
}

// ── Core transaction: apply one behavior event to the state ────────────────
// event = { facet, delta, note }  (delta > 0 positive, delta < 0 negative)
// Returns a result describing what happened (for UI feedback / testing).
// MUTATES state in place (the caller owns cloning if it wants immutability).
function applyEvent(state, event) {
    var res = { applied: false, frozen: false, absorbed: 0, overflow: 0, reframedTo: null, reframedAmount: 0 };
    if (state.isRestModeActive) { res.frozen = true; return res; }  // Tavern Protocol: whole engine frozen

    var f = state.facets[event.facet];
    if (!f) return res;
    res.applied = true;

    if (event.delta >= 0) {
        // Positive behavior: permanent XP grows, expression rises. Never
        // touches the shield.
        f.xp += event.delta * XP_PER_POINT;
        f.score = clamp(f.score + event.delta, 0, 100);
    } else {
        var mag = -event.delta;
        // FOCUS POINTS absorb first — the buffer you built by behaving well.
        // Denominated in FP (FP_PER_POINT per point of facet delta), so a
        // 2-facet rupture costs twice a 1-facet slip.
        var cost      = mag * FP_PER_POINT;
        var absorbedFp = Math.min(state.vitals.fp, cost);
        state.vitals.fp -= absorbedFp;
        var overflow  = (cost - absorbedFp) / FP_PER_POINT;   // back into "points"
        res.absorbed = absorbedFp;                            // in FP
        res.overflow = overflow;                              // in points

        // Current expression drops by the full magnitude (a bad stretch shows
        // up in the trait *now*, recoverably) ...
        f.score = clamp(f.score - mag, 0, 100);

        // ... but Reframing routes a fraction to a complementary facet.
        var target = REFRAME[event.facet];
        if (target && state.facets[target]) {
            var bonus = mag * RESPEC_RATIO;
            state.facets[target].score = clamp(state.facets[target].score + bonus, 0, 100);
            res.reframedTo = target;
            res.reframedAmount = bonus;
        }

        // Permanent XP is only ever threatened by overflow past a broken
        // shield — and even then only via the deferred decay ledger, never
        // applied here in real time.
        if (overflow > 0) f.pendingDecay += overflow * XP_PER_POINT;
    }
    return res;
}

// ── Behavior logging: translate a tracked real-world signal into facet events ─
// signalKey ∈ keys(BEHAVIOR_MAP); intensity is a magnitude (default 1). Returns
// the per-facet applyEvent results. This is the seam a real input layer calls.
function logBehavior(state, signalKey, intensity) {
    var moves = BEHAVIOR_MAP[signalKey];
    if (!moves) return [];
    var mag = Math.abs(intensity === undefined || intensity === null ? 1 : intensity);
    var results = [];
    for (var i = 0; i < moves.length; i++)
        results.push(applyEvent(state, { facet: moves[i].facet, delta: moves[i].sign * mag, note: signalKey }));
    // NEGATIVE signals already drained FP inside applyEvent (the shield path) —
    // don't charge them twice. POSITIVE signals earn FP from the gains table on
    // top of their facet XP.
    var fpGained = awardFp(state, signalKey, mag);
    return { facets: results, fp: fpGained, signal: signalKey };
}

// ── Scheduled check-in: the ONLY place permanent XP can actually drop ──────
// Compiles every facet's accumulated pendingDecay into real XP loss. Frozen
// during Rest Mode. Returns per-facet applied losses (for a summary UI).
// (HP used to be worn down here too; now that HP is a pure calories-eaten
// readout, decay only touches XP.)
function runCheckIn(state, nowEpoch) {
    if (state.isRestModeActive) return { frozen: true, losses: {} };
    var losses = {};
    var keys = allFacetKeys();
    for (var i = 0; i < keys.length; i++) {
        var f = state.facets[keys[i]];
        if (f.pendingDecay > 0) {
            var applied = Math.min(f.xp, f.pendingDecay);
            f.xp -= applied;
            losses[keys[i]] = applied;
        }
        f.pendingDecay = 0;
    }
    state.lastCheckIn = nowEpoch || state.lastCheckIn;
    return { frozen: false, losses: losses };
}

// Total pending decay still queued (surfaced in UI as "will apply at check-in").
function totalPendingDecay(state) {
    var sum = 0, keys = allFacetKeys();
    for (var i = 0; i < keys.length; i++) sum += state.facets[keys[i]].pendingDecay;
    return sum;
}

// ── Daily reset: renew the shield + refill vitals (frozen during Rest Mode) ─
function dailyReset(state, nowEpoch) {
    if (state.isRestModeActive) return false;
    // FOCUS POINTS DO NOT REFILL. This is the whole point: FP is earned, not
    // granted. A new day only ever takes from it —
    //   • a reactivity tax (a day spent absorbing other people's emotional
    //     weather is paid for out of focus), and
    //   • a small idle decay if you earned nothing at all yesterday.
    var fpTax = Math.round(REACTIVITY_FP_TAX * reactivityOf(state));
    if (!state.fpEarnedToday) fpTax += FP_IDLE_DECAY;
    state.vitals.fp = clamp(state.vitals.fp - fpTax, 0, state.vitals.fpMax);
    state.fpEarnedToday = 0;
    // A new day: today's consumption counters restart, then every gauge is
    // recomputed as a pure readout — including HP's calorie budget (hpMax),
    // which resets to the profile baseline until exercise is logged.
    state.trackers.nutrition.calories = 0;
    state.trackers.nutrition.drinkCalories = 0;
    state.trackers.nutrition.protein = 0;
    state.trackers.nutrition.carbs = 0;
    state.trackers.nutrition.fat = 0;
    state.trackers.nutrition.meals = 0;
    state.trackers.intake = emptyIntake();
    syncVitalsFromTrackers(state);
    state.lastDailyReset = nowEpoch || state.lastDailyReset;
    return true;
}

// ── Aggregations for the UI ────────────────────────────────────────────────
function dimensionSummary(state, dimKey) {
    var dim = null;
    for (var i = 0; i < DIMENSIONS.length; i++) if (DIMENSIONS[i].key === dimKey) dim = DIMENSIONS[i];
    if (!dim) return null;
    var xp = 0, scoreSum = 0, facetList = [];
    for (var j = 0; j < dim.facets.length; j++) {
        var fk = dim.facets[j].key, f = state.facets[fk];
        xp += f.xp;
        scoreSum += f.score;
        facetList.push({
            key: fk, name: dim.facets[j].name,
            xp: f.xp, level: levelForXp(f.xp), progress: levelProgress(f.xp),
            score: f.score, pendingDecay: f.pendingDecay
        });
    }
    return {
        key: dim.key, name: dim.name, glyph: dim.glyph,
        xp: xp, level: levelForXp(xp), progress: levelProgress(xp),
        avgScore: scoreSum / dim.facets.length,
        facets: facetList
    };
}

function computeDangerZones(state) {
    // Build a flat {facetKey: score} map for the predicates.
    var sc = {}, keys = allFacetKeys();
    for (var i = 0; i < keys.length; i++) sc[keys[i]] = state.facets[keys[i]].score;
    var active = [];
    for (var z = 0; z < DANGER_ZONES.length; z++) {
        if (DANGER_ZONES[z].test(sc)) active.push({
            key: DANGER_ZONES[z].key, dim: DANGER_ZONES[z].dim,
            name: DANGER_ZONES[z].name, desc: DANGER_ZONES[z].desc
        });
    }
    return active;
}

function dangerZonesForDim(state, dimKey) {
    return computeDangerZones(state).filter(function (z) { return z.dim === dimKey; });
}

function totalXp(state) {
    var sum = 0, keys = allFacetKeys();
    for (var i = 0; i < keys.length; i++) sum += state.facets[keys[i]].xp;
    return sum;
}
function characterLevel(state) { return levelForXp(totalXp(state)); }

// ── Objective-proxy & lifestyle-tracker helpers ────────────────────────────
// Resilience Index: a LEADING indicator (per the brief, an HRV drop below
// baseline predicts a resilience dip 24–48h before it's consciously felt).
// Blends HRV-vs-baseline (60%) with sleep quality — deep+REM share (40%).
// 0-100; a low value is an early warning, surfaced in the UI ahead of any
// subjective report.
function resilienceIndex(state) {
    var b = state.trackers.biometrics;
    var hrvRatio = b.hrvBaseline > 0 ? clamp(b.hrv / b.hrvBaseline, 0, 1) : 1;
    var sleepQ = clamp((b.deepPct + b.remPct) / 45, 0, 1);   // ~45% deep+REM ≈ good architecture
    return Math.round(100 * (0.6 * hrvRatio + 0.4 * sleepQ));
}

// Dependency status vs its self-set cap: "under" | "at" | "over".
function dependencyStatus(dep) {
    if (dep.count > dep.limit) return "over";
    if (dep.count >= dep.limit) return "at";
    return "under";
}

// ── Vitals ⇄ tracked domains ───────────────────────────────────────────────
// Each of the seven vital gauges is the live readout of a real tracked domain.
// NB: the engine KEY always matches the on-screen LABEL, so they can't drift.
//   HP  (Fuel)     ← calories eaten vs TODAY'S personal target — hpMax IS the
//                    day's calorie budget (profile BMR × activity + exercise ± goal)
//   PP  (Potions)  ← ml drunk vs TODAY'S water target — ppMax IS the day's ml
//                    budget. Every drink is a POTION with real side effects.
//   AP  (Exercise) ← SECONDS of training vs the profile-derived daily need
//   MP  (Energy)   ← circumplex arousal × bodily resources (0-100)
//   EP  (Sleep)    ← last night's sleepQuality: duration + deep/REM + latency (0-100)
//   SP  (Soul)     ← inverse of stress load (0-100; full bar = calm)
//   FP  (Focus)    ← PERSISTENT 0-400 behavioural score; drained by bad
//                    behaviour, rebuilt by hard wins & repairs; shields XP
// The "supply" scores below are 0-1 and drive both the gauge value and the
// breakdown shown on each vital's detail page.
function movementScore(state) {
    var m = state.trackers.movement;
    var steps = clamp(m.steps / Math.max(1, m.stepTarget), 0, 1);
    var act   = clamp(m.activeMin / Math.max(1, m.activeTarget), 0, 1);
    var wk    = clamp(m.workouts / Math.max(1, m.workoutTarget), 0, 1);
    return clamp(0.4 * steps + 0.3 * act + 0.3 * wk, 0, 1);
}

// Recompute the derived gauges from today's tracked inputs. All six are pure
// readouts now: HP is calories-eaten against a per-day calorie budget (hpMax
// itself moves with tracked exercise — train more, earn a bigger tank), the
// rest read water / exercise / mood / inverse-stress; WS is left to the
// daily-reset / shield mechanic.
function syncVitalsFromTrackers(state) {
    // If a full sleep hypnogram was logged, it is the SOURCE OF TRUTH: derive the
    // sleep biometrics from it so the EP gauge can never disagree with the graph.
    var ss = sleepSession(state);
    if (ss) {
        var b = state.trackers.biometrics;
        b.sleepHours = Math.round(ss.asleepMin / 6) / 10;   // minutes → hours, 1dp
        b.deepPct    = ss.stages[0].pct;                    // stages[0] = deep
        b.remPct     = ss.stages[1].pct;                    // stages[1] = rem
        // sleep latency = the first Awake block, if the night opens with one
        if (ss.segments.length && ss.segments[0].stage === "awake")
            b.sleepLatencyMin = ss.segments[0].min;
    }
    // Movement targets come from the profile (age + goal), not hand-set numbers.
    var ex = dailyExerciseTargets();
    state.trackers.movement.stepTarget    = ex.steps;
    state.trackers.movement.activeTarget  = ex.activeMin;
    state.trackers.movement.workoutTarget = ex.workouts;
    // nutrition.calories ALREADY includes liquid calories — drink() folds sugar
    // and ethanol in at log time. Do NOT add drinkCalories() here or they'd be
    // counted twice.
    // These three are ACCUMULATING counters — they may tick PAST their target
    // (the bar shows the overflow in a second shade), so they are NOT clamped to
    // max; only floored at 0.
    state.vitals.hpMax = dailyCalorieTarget(state);
    state.vitals.hp = Math.max(0, state.trackers.nutrition.calories);
    state.vitals.ppMax = dailyWaterTarget(state);
    state.vitals.pp = Math.max(0, state.trackers.intake.waterMl);
    // AP = MINUTES of Zone 2 today, against a 60 min/day target.
    state.trackers.movement.zone2Target = ZONE2_TARGET_MIN;
    state.vitals.apMax = ZONE2_TARGET_MIN;
    state.vitals.ap = Math.max(0, Math.round(zone2Today(state).min));
    // MP is ENERGY: circumplex arousal backed by real bodily resources.
    state.vitals.mp = Math.round(state.vitals.mpMax * energyLevel(state) / 100);
    // EP is SLEEP: last night's quality (duration + architecture + latency).
    state.vitals.ep = Math.round(state.vitals.epMax * sleepQuality(state) / 100);
    state.vitals.sp = Math.round(state.vitals.spMax * (1 - stressLevel(state) / 100));
    return state;
}

// Static metadata for each vital's detail page.
var VITAL_INFO = {
    hp: { key: "hp", label: "HP", name: "Hunger",     glyph: "", accent: "red",
          tagline: "Calories eaten vs today's personal budget — the max grows on days you train." },
    // Hydration → "Potions". Engine key is `pp` (keys match labels so they
    // can't drift). Every drink is a potion with its own side effects — see POTIONS.
    pp: { key: "pp", label: "PP", name: "Potions",    glyph: "", accent: "blue",
          tagline: "Millilitres drunk vs today's need. Every drink is a potion — each with its own side effects." },
    ap: { key: "ap", label: "AP", name: "Stamina",    glyph: "", accent: "yellow",
          tagline: "Minutes of Zone 2 today, against 60/day — goes golden once your steps are in." },
    // Energy now wears the MP label (mana = the pool you act out of).
    mp: { key: "mp", label: "MP", name: "Mind",       glyph: "", accent: "peach",
          tagline: "Usable energy — how activated you are, backed by sleep, fuel, water and recovery." },
    // Sleep inherits the EP slot.
    ep: { key: "ep", label: "EP", name: "Resting",    glyph: "", accent: "mauve",
          tagline: "Last night's sleep quality — duration, deep+REM architecture, and how fast you dropped off." },
    sp: { key: "sp", label: "SP", name: "Soul",       glyph: "", accent: "green",
          tagline: "Calm under load — a full soul means low stress; strain wears it down." },
    fp: { key: "fp", label: "FP", name: "Focus",      glyph: "", accent: "teal",
          tagline: "Earned, never granted. Bad behaviour drains it; hard wins and repairs rebuild it. It shields your XP." }
};
function vitalInfo(key) { return VITAL_INFO[key] || null; }

// The contributing-input breakdown shown on a vital's detail page.
// `nOverride` (optional) swaps in another day's nutrition totals, so the HP page
// can render a PAST day pulled from the food-log history.
function vitalBreakdown(state, key, nOverride) {
    var t = state.trackers;
    if (key === "hp") {
        var n = nOverride || t.nutrition, target = dailyCalorieTarget(state), p = USER_PROFILE;
        var liquid = drinkCalories(state);
        var solid  = Math.max(0, n.calories - liquid);
        var mac = dailyMacros(state);
        // The three MACROS → Nutrition (a `tail` row rendered AFTER the macro
        // bars). Calories is the big gauge bar; the meal COUNT is now the MEALS
        // section header, so it's no longer a row here.
        return [
            { label: "Protein",   ratio: n.protein / Math.max(1, mac.protein), valueText: n.protein + " / " + mac.protein + " g", macro: true },
            { label: "Carbs",     ratio: n.carbs / Math.max(1, mac.carb),      valueText: n.carbs + " / " + mac.carb + " g", macro: true },
            { label: "Fat",       ratio: n.fat / Math.max(1, mac.fat),         valueText: n.fat + " / " + mac.fat + " g", macro: true },
            { label: "Nutrition", ratio: n.quality / 100,                      valueText: "Q" + n.quality, tail: true }
        ];
    }
    if (key === "pp") {
        var wTarget = dailyWaterTarget(state), env = t.environment, ik = t.intake;
        // Drunk / Base / Exercise / Heat now live in the small segment bar under
        // the gauge, not as rows here.
        var rows = [];
        // ELECTROLYTES (sodium): a daily need of ~1500 mg adequate intake +
        // ~500 mg per active hour of sweat loss (+300 mg on a hot day). Losing
        // water without replacing sodium is why plain water can leave you flat —
        // so this line keeps you on top of it.
        var sweatH = state.trackers.movement.activeMin / 60 + (heatBonusMl(state) > 0 ? 1 : 0);
        function elrow(label, mgIn, target, unit) {
            return { label: label, ratio: mgIn / Math.max(1, target),
                     valueText: mgIn + " / " + target + " mg"
                              + (mgIn < target * 0.5 ? " ⚠" : mgIn >= target ? " ✓" : "") };
        }
        var isF = USER_PROFILE.sex === "female";
        // Sodium: 1500 mg adequate + ~500 mg per sweat-hour. Potassium: ~3400/2600
        // adequate (raised a little for sweat). Magnesium: ~420/320.
        rows.push(elrow("Sodium",    Math.round(ik.sodiumMg),    Math.round(1500 + sweatH * 500)));
        rows.push(elrow("Potassium", Math.round(ik.potassiumMg), Math.round((isF ? 2600 : 3400) + sweatH * 200)));
        rows.push(elrow("Magnesium", Math.round(ik.magnesiumMg), isF ? 320 : 420));
        // Caffeine / Alcohol / Sugar are no longer rows — they render as the
        // pixel-art POTIONS above (see potionLines). These electrolyte rows are
        // the "Ingredients" list.
        return rows;
    }
    if (key === "ep") {
        // No rows: duration, architecture, latency and quality are all READABLE OFF
        // THE HYPNOGRAM below, so bars here would just restate the graph. Quality
        // rides in the graph's header (see sleepQualityParts).
        return [];
    }
    if (key === "mp") {
        var af = affectState(state), v = state.vitals;
        return [
            { label: "Activation", ratio: (af.arousal + 1) / 2,
              valueText: (af.arousal >= 0 ? "+" : "") + Math.round(af.arousal * 100) / 100 + " (" + af.source + ")" },
            { label: "Sleep",      ratio: sleepQuality(state) / 100,            valueText: "Q" + sleepQuality(state) },
            { label: "Recovery",   ratio: resilienceIndex(state) / 100,         valueText: resilienceIndex(state) + " / 100" },
            { label: "Fuel",       ratio: v.hpMax > 0 ? v.hp / v.hpMax : 0,     valueText: Math.round((v.hpMax > 0 ? v.hp / v.hpMax : 0) * 100) + "% kcal" },
            { label: "Water",      ratio: v.ppMax > 0 ? v.pp / v.ppMax : 0,  valueText: Math.round((v.ppMax > 0 ? v.pp / v.ppMax : 0) * 100) + "% ml" },
            { label: "State",      ratio: energyLevel(state) / 100,             valueText: energyLabel(state) }
        ];
    }
    if (key === "sp") {
        var b2 = t.biometrics;
        var hrvStrain = b2.hrvBaseline > 0 ? clamp(1 - b2.hrv / b2.hrvBaseline, 0, 1) : 0;
        var al = allostaticLoad(state), ps = pssStatus(state);
        // Acute (today's) load first, then the SLOW long-term pair (objective
        // wear + perceived stress) — different timescales, deliberately not
        // blended into one number.
        return [
            { label: "HRV strain", ratio: hrvStrain,                                valueText: Math.round(hrvStrain * 100) + "%" },
            { label: "Anxiety",    ratio: state.facets.anxiety.score / 100,         valueText: Math.round(state.facets.anxiety.score) + " / 100" },
            { label: "Digital",    ratio: clamp(b2.screenMin / 600, 0, 1),          valueText: Math.round(b2.screenMin / 60) + "h screen" },
            { label: "Sleep debt", ratio: 1 - clamp(b2.sleepHours / 8, 0, 1),       valueText: b2.sleepHours + " h slept" },
            { label: "Wear (z)",   ratio: clamp((al.zMean + 1) / 3, 0, 1),   // −1σ…+2σ mapped to the bar
              valueText: al.zCount ? ((al.zMean > 0 ? "+" : "") + al.zMean + " " + allostaticDriftLabel(al))
                                   : (al.measured + "/" + al.total + " markers") },
            { label: "Perceived",  ratio: ps.score !== null ? ps.score / 40 : 0,
              valueText: ps.score !== null ? (ps.score + "/40 " + ps.label) : "PSS-10 not taken" }
        ];
    }
    if (key === "ap") {
        var m = t.movement;
        var km = Math.round(m.steps * 0.000762 * 10) / 10;     // ~0.76 m stride
        // Zone 2 and the heart-rate bands are NOT rows — they live in the WORKOUT
        // tracker below the bars (see hrZones / workoutLog). These are the
        // supporting context. The per-limb worked/rested state is still tracked —
        // it drives the figure's blood vessels — just not listed.
        return [
            // Steps can tick PAST target (the bar shows the overflow in a 2nd shade).
            { label: "Steps",    ratio: m.steps / Math.max(1, m.stepTarget),        valueText: m.steps + " / " + m.stepTarget + (stepsGoalMet(state) ? " ✓" : "") },
            { label: "Distance", ratio: clamp(km / 6, 0, 1),                        valueText: km + " km" },
            { label: "Burned",   ratio: clamp(exerciseCalories(state) / 600, 0, 1), valueText: "+" + exerciseCalories(state) + " kcal" }
        ];
    }
    if (key === "fp") {
        var r = reactivityOf(state), v = state.vitals;
        var pend = totalPendingDecay(state);
        return [
            { label: "Focus",      ratio: v.fp / v.fpMax,          valueText: v.fp + " / " + v.fpMax + " · " + fpLabel(v.fp) },
            { label: "Earned today", ratio: clamp((state.fpEarnedToday || 0) / 40, 0, 1),
              valueText: "+" + (state.fpEarnedToday || 0) + " FP" },
            { label: "Gain rate",  ratio: fpGainScale(v.fp),       valueText: Math.round(fpGainScale(v.fp) * 100) + "% (harder as you climb)" },
            // Reactivity is paid for out of focus: regulating against other
            // people's emotional weather is what SPENDS it.
            { label: "Reactivity", ratio: r,                       valueText: reactivityLabel(r) + " · −" + Math.round(REACTIVITY_FP_TAX * r) + "/day" },
            { label: "Shielding",  ratio: v.fp > 0 ? 1 : 0,
              valueText: v.fp > 0 ? "XP protected" : "XP EXPOSED" },
            { label: "Queued loss", ratio: clamp(pend / 500, 0, 1), valueText: pend > 0 ? Math.round(pend) + " XP at check-in" : "none" }
        ];
    }
    return [];
}

// ── ALLOSTATIC LOAD ────────────────────────────────────────────────────────
// The research-grade measure of cumulative physiological "wear and tear" from
// chronic stress. Operationalized per Seeman/McEwen (MacArthur Studies, 1997)
// and the extended multi-system panel of Juster & McEwen (2010): a set of
// biomarkers across four physiological systems; each marker scores 1 point when
// it sits in the high-risk range; the points are summed.
//
// TWO DELIBERATE DEVIATIONS FROM THE PUBLISHED METHOD — both forced, both
// surfaced rather than hidden:
//  1. SCORING. The canonical index scores a marker 1 if it falls in the
//     highest-risk QUARTILE of a reference POPULATION. A single person has no
//     quartiles. So we use published CLINICAL cutoffs instead (ATP III, ADA,
//     AHA/CDC, WHO) — a legitimate, widely-published AL variant, but it is NOT
//     quartile scoring and shouldn't be compared to population AL numbers.
//  2. COVERAGE. Most canonical markers require blood/urine assays. Whatever is
//     missing is simply NOT scored, and `coverage` reports how much of the
//     panel was actually measured. A 3-of-15 index is reported as such — never
//     rescaled to look complete.
//
// Marker sources: "lab" (blood/urine panel — you enter these), "home" (BP cuff,
// tape measure — you enter these), "wearable" (HRV/RHR feed), "derived"
// (computed from the profile). Anything not "derived"/"wearable" is only present
// if you supply it in trackers.labs.
var ALLOSTATIC_SPEC = [
    // ── Primary mediators (neuroendocrine — the stress hormones themselves) ──
    { key: "cortisol",       system: "Neuroendocrine", name: "Cortisol",         unit: "µg/dL",   source: "lab",
      risk: function (v) { return v >= 23; },   note: "morning serum; >23 µg/dL high" },
    { key: "dheas",          system: "Neuroendocrine", name: "DHEA-S",           unit: "µg/dL",   source: "lab",
      risk: function (v) { return v <= 80; },   note: "REVERSE-coded (low = risk); strongly age-dependent — a proper norm needs age-specific quartiles" },
    { key: "epinephrine",    system: "Neuroendocrine", name: "Epinephrine",      unit: "µg/g cr", source: "lab",
      risk: function (v) { return v >= 5; },    note: "12-h urinary catecholamine; rarely ordered" },
    { key: "norepinephrine", system: "Neuroendocrine", name: "Norepinephrine",   unit: "µg/g cr", source: "lab",
      risk: function (v) { return v >= 48; },   note: "12-h urinary catecholamine; rarely ordered" },

    // ── Cardiovascular ──────────────────────────────────────────────────────
    { key: "sbp",            system: "Cardiovascular", name: "Systolic BP",      unit: "mmHg",    source: "home",
      risk: function (v) { return v >= 130; },  note: "2017 ACC/AHA stage-1 hypertension" },
    { key: "dbp",            system: "Cardiovascular", name: "Diastolic BP",     unit: "mmHg",    source: "home",
      risk: function (v) { return v >= 80; },   note: "2017 ACC/AHA stage-1 hypertension" },
    { key: "rhr",            system: "Cardiovascular", name: "Resting HR",       unit: "bpm",     source: "wearable",
      risk: function (v) { return v >= 80; },   note: "elevated resting heart rate" },
    { key: "hrv",            system: "Cardiovascular", name: "HRV vs baseline",  unit: "ratio",   source: "wearable",
      risk: function (v) { return v <= 0.8; },  note: "REVERSE-coded; RMSSD as a fraction of YOUR OWN baseline (raw ms is not comparable between people)" },

    // ── Metabolic ───────────────────────────────────────────────────────────
    { key: "whr",            system: "Metabolic",      name: "Waist-hip ratio",  unit: "",        source: "home",
      risk: function (v) { return v >= (USER_PROFILE.sex === "female" ? 0.85 : 0.90); }, note: "WHO abdominal-obesity cutoff (sex-specific)" },
    { key: "bmi",            system: "Metabolic",      name: "BMI",              unit: "kg/m²",   source: "derived",
      risk: function (v) { return v >= 30; },   note: "WHO obesity threshold; derived from profile weight+height" },
    { key: "hdl",            system: "Metabolic",      name: "HDL cholesterol",  unit: "mg/dL",   source: "lab",
      risk: function (v) { return v < (USER_PROFILE.sex === "female" ? 50 : 40); }, note: "REVERSE-coded (low = risk); ATP III" },
    { key: "tc_hdl",         system: "Metabolic",      name: "Total chol / HDL", unit: "ratio",   source: "derived",
      risk: function (v) { return v >= 5.0; },  note: "the MacArthur lipid marker; derived when both labs present" },
    { key: "hba1c",          system: "Metabolic",      name: "HbA1c",            unit: "%",       source: "lab",
      risk: function (v) { return v >= 5.7; },  note: "ADA prediabetes threshold" },

    // ── Immune / inflammatory (the modern extension) ────────────────────────
    { key: "crp",            system: "Inflammatory",   name: "hs-CRP",           unit: "mg/L",    source: "lab",
      risk: function (v) { return v >= 3.0; },  note: "AHA/CDC high cardiovascular-risk band" },
    { key: "il6",            system: "Inflammatory",   name: "IL-6",             unit: "pg/mL",   source: "lab",
      risk: function (v) { return v >= 3.0; },  note: "commonly used cutoff; less standardized than CRP" },
    { key: "fibrinogen",     system: "Inflammatory",   name: "Fibrinogen",       unit: "mg/dL",   source: "lab",
      risk: function (v) { return v >= 400; },  note: "upper end of the normal range" }
];

// ── Continuous (z-score) allostatic load ──────────────────────────────────
// The binary threshold count above is the classic formulation, but it is BLIND
// INSIDE THE NORMAL RANGE: a healthy person's markers all sit under their
// cutoffs, so the count reads 0 and stays 0 no matter how the markers drift.
// The literature's answer is the CONTINUOUS formulation — express each marker
// as a z-score against a population reference and sum them. Sub-clinical drift
// (HbA1c 5.2 → 5.5, still "normal") becomes visible. Both are computed; the UI
// shows both, because they answer different questions:
//   count → "how many systems have crossed into clinical risk?"  (damage)
//   z-sum → "which way, and how far, am I drifting?"             (early signal)
//
// HONESTY ABOUT THE REFERENCES: proper AL z-scoring uses the mean/SD of a
// reference COHORT. These are approximate adult population values (NHANES-era
// literature), sex-specific where it matters. They are good enough to make
// DRIFT and RELATIVE position meaningful; they are NOT a validated cohort, so
// don't read the absolute z-sum as a clinical number.
// `dir` = +1 when HIGH is bad, -1 when LOW is bad (HDL, DHEA-S, HRV) — the
// z-score is signed so POSITIVE ALWAYS MEANS MORE LOAD.
// `log: true` for right-skewed markers (CRP, IL-6) — the literature log-
// transforms these before z-scoring.
var ALLOSTATIC_REF = {
    cortisol:       { mean: 12,   sd: 5,    dir:  1 },
    dheas:          { mean: 350,  sd: 130,  dir: -1, ageAdjust: true },  // falls ~2%/yr after 30
    epinephrine:    { mean: 2.5,  sd: 1.5,  dir:  1 },
    norepinephrine: { mean: 30,   sd: 14,   dir:  1 },
    sbp:            { mean: 120,  sd: 15,   dir:  1 },
    dbp:            { mean: 75,   sd: 10,   dir:  1 },
    rhr:            { mean: 70,   sd: 10,   dir:  1 },
    hrv:            { mean: 1.0,  sd: 0.15, dir: -1 },                   // ratio to your OWN baseline
    whr:            { mean: 0.90, sd: 0.07, dir:  1, female: { mean: 0.80, sd: 0.07 } },
    bmi:            { mean: 27,   sd: 5.5,  dir:  1 },
    hdl:            { mean: 48,   sd: 13,   dir: -1, female: { mean: 58, sd: 15 } },
    tc_hdl:         { mean: 4.0,  sd: 1.2,  dir:  1 },
    hba1c:          { mean: 5.5,  sd: 0.5,  dir:  1 },
    crp:            { mean: 0.4,  sd: 0.9,  dir:  1, log: true },        // log10(mg/L)
    il6:            { mean: 0.2,  sd: 0.4,  dir:  1, log: true },        // log10(pg/mL)
    fibrinogen:     { mean: 300,  sd: 60,   dir:  1 }
};

// Signed z-score for one marker: positive = more allostatic load, always.
function markerZ(key, value) {
    var r = ALLOSTATIC_REF[key];
    if (!r || value === null || value === undefined) return null;
    var mean = r.mean, sd = r.sd;
    if (USER_PROFILE.sex === "female" && r.female) { mean = r.female.mean; sd = r.female.sd; }
    // DHEA-S declines with age; comparing a 60-year-old to a 25-year-old's mean
    // would score normal aging as stress. Shift the reference ~2%/yr past 30.
    if (r.ageAdjust && USER_PROFILE.age > 30)
        mean = mean * Math.pow(0.98, USER_PROFILE.age - 30);
    var v = value;
    if (r.log) {
        if (v <= 0) return null;
        v = Math.log(v) / Math.LN10;
    }
    if (sd <= 0) return null;
    return ((v - mean) / sd) * r.dir;
}

var LAB_STALE_DAYS  = 365;   // a blood panel older than a year is stale
var HOME_STALE_DAYS = 90;    // BP / tape measurements older than a quarter are stale
var DAY_SECONDS = 86400;

function bmiOf(p) {
    var m = p.heightCm / 100;
    return m > 0 ? p.weightKg / (m * m) : 0;
}

// Assemble every marker's CURRENT value from wherever it legitimately comes
// from. Returns { key: {value, ageDays} } — absent keys are genuinely unmeasured.
function allostaticInputs(state, nowEpoch) {
    var now = nowEpoch || (Date.now() / 1000);
    var labs = state.trackers.labs || {};
    var b = state.trackers.biometrics;
    var out = {};

    function fromEntry(key, entry, staleDays) {
        if (!entry || entry.value === null || entry.value === undefined) return;
        var ageDays = entry.date ? (now - entry.date) / DAY_SECONDS : 0;
        if (ageDays > staleDays) return;   // stale → treat as unmeasured, not as "fine"
        out[key] = { value: entry.value, ageDays: Math.round(ageDays) };
    }

    for (var i = 0; i < ALLOSTATIC_SPEC.length; i++) {
        var spec = ALLOSTATIC_SPEC[i];
        if (spec.source === "lab")  fromEntry(spec.key, labs[spec.key], LAB_STALE_DAYS);
        if (spec.source === "home") fromEntry(spec.key, labs[spec.key], HOME_STALE_DAYS);
    }
    // Wearable-fed, live.
    if (b.rhr > 0) out.rhr = { value: b.rhr, ageDays: 0 };
    if (b.hrv > 0 && b.hrvBaseline > 0) out.hrv = { value: Math.round(b.hrv / b.hrvBaseline * 100) / 100, ageDays: 0 };
    // Derived.
    var bmi = bmiOf(USER_PROFILE);
    if (bmi > 0) out.bmi = { value: Math.round(bmi * 10) / 10, ageDays: 0 };
    if (out.hdl === undefined && labs.hdl && labs.hdl.value) { /* hdl handled above; nothing */ }
    if (labs.total_cholesterol && labs.total_cholesterol.value && labs.hdl && labs.hdl.value) {
        var tcAge = labs.total_cholesterol.date ? (now - labs.total_cholesterol.date) / DAY_SECONDS : 0;
        if (tcAge <= LAB_STALE_DAYS && labs.hdl.value > 0)
            out.tc_hdl = { value: Math.round(labs.total_cholesterol.value / labs.hdl.value * 10) / 10, ageDays: Math.round(tcAge) };
    }
    return out;
}

// The four physiological systems of the canonical model. Tracked explicitly so
// the reliability check can see when a whole system is unmeasured.
var ALLOSTATIC_SYSTEMS = ["Neuroendocrine", "Cardiovascular", "Metabolic", "Inflammatory"];

// The index itself. Computes BOTH formulations (binary threshold count and
// continuous z-sum), reports coverage per system, and refuses to call itself
// reliable when whole systems are blind — so the UI can NEVER present a partial
// or structurally lopsided index as complete.
function allostaticLoad(state, nowEpoch) {
    var inputs = allostaticInputs(state, nowEpoch);
    var markers = [], missing = [], score = 0, measured = 0, zSum = 0, zCount = 0;
    var bySystem = {};
    for (var s = 0; s < ALLOSTATIC_SYSTEMS.length; s++)
        bySystem[ALLOSTATIC_SYSTEMS[s]] = { measured: 0, atRisk: 0, total: 0, zSum: 0 };

    for (var i = 0; i < ALLOSTATIC_SPEC.length; i++) {
        var spec = ALLOSTATIC_SPEC[i];
        bySystem[spec.system].total++;
        var got = inputs[spec.key];
        if (!got) {
            missing.push({ key: spec.key, name: spec.name, system: spec.system, source: spec.source });
            markers.push({ key: spec.key, name: spec.name, system: spec.system, unit: spec.unit,
                           source: spec.source, measured: false, atRisk: false, value: null,
                           z: null, ageDays: null, note: spec.note });
            continue;
        }
        measured++;
        var atRisk = spec.risk(got.value);
        var z = markerZ(spec.key, got.value);
        if (atRisk) score++;
        bySystem[spec.system].measured++;
        if (atRisk) bySystem[spec.system].atRisk++;
        if (z !== null) { zSum += z; zCount++; bySystem[spec.system].zSum += z; }
        markers.push({ key: spec.key, name: spec.name, system: spec.system, unit: spec.unit,
                       source: spec.source, measured: true, atRisk: atRisk, value: got.value,
                       z: z === null ? null : Math.round(z * 100) / 100,
                       ageDays: got.ageDays, note: spec.note });
    }

    // How many of the four systems have ANY measured marker — the structural
    // check the old count-only reliability flag was missing.
    var systemsCovered = 0, blindSystems = [];
    for (var k = 0; k < ALLOSTATIC_SYSTEMS.length; k++) {
        var sys = ALLOSTATIC_SYSTEMS[k];
        if (bySystem[sys].measured > 0) systemsCovered++;
        else blindSystems.push(sys);
    }

    var total = ALLOSTATIC_SPEC.length;
    return {
        // ── binary formulation (classic Seeman/McEwen) ──
        score: score,                                  // markers in the clinical high-risk range
        ratio: measured > 0 ? score / measured : 0,
        // ── continuous formulation (z-sum; sees sub-clinical drift) ──
        zSum: Math.round(zSum * 100) / 100,            // total drift, + = more load
        zMean: zCount > 0 ? Math.round(zSum / zCount * 100) / 100 : 0,
        zCount: zCount,
        // ── coverage & structure ──
        measured: measured,
        total: total,
        coverage: measured / total,
        bySystem: bySystem,
        systemsCovered: systemsCovered,
        blindSystems: blindSystems,                    // systems with ZERO measured markers
        markers: markers,
        missing: missing,
        // Reliable requires BOTH enough markers AND representation across at
        // least 3 of the 4 systems. A 9-marker index that is blind to the
        // neuroendocrine and inflammatory axes is a cardiometabolic risk score,
        // not an allostatic one — it must not claim otherwise.
        reliable: measured >= 8 && systemsCovered >= 3
    };
}

// Plain-language band for the BINARY count (only meaningful when `reliable`).
// NOTE: for a healthy person this saturates at "Low" — it counts damage, not
// stress. Use the z-drift band below for early signal.
function allostaticLabel(al) {
    if (!al.reliable) return "Insufficient data";
    if (al.score <= 1) return "Low";
    if (al.score <= 3) return "Moderate";
    if (al.score <= 5) return "High";
    return "Very High";
}

// Plain-language band for the CONTINUOUS drift (mean z across measured markers).
// This is the one that still has resolution when every marker is "normal".
function allostaticDriftLabel(al) {
    if (al.zCount === 0) return "No data";
    var z = al.zMean;
    if (z <= -0.5) return "Well below average";
    if (z <= -0.2) return "Below average";
    if (z <  0.2)  return "Average";
    if (z <  0.5)  return "Above average";
    if (z <  1.0)  return "Elevated";
    return "Strongly elevated";
}

// ── PSS-10: Perceived Stress Scale (Cohen, 1983) ───────────────────────────
// The most-validated stress instrument in the literature, reproduced verbatim.
// 10 items about THE LAST MONTH, each 0-4 (0 never … 4 very often). Items 4, 5,
// 7 and 8 are REVERSE-scored (they ask about coping, so high = less stress).
// Total 0-40: ≤13 low, 14-26 moderate, ≥27 high perceived stress.
//
// Why it earns its place: allostatic load measures physiological DAMAGE, which
// in a healthy person reads ~0 no matter how stressed they are. The PSS measures
// PERCEIVED load, which has full resolution at zero damage. Objective + subjective
// is the standard pairing in the stress literature — neither substitutes for the
// other.
var PSS10_ITEMS = [
    { n: 1,  reverse: false, text: "In the last month, how often have you been upset because of something that happened unexpectedly?" },
    { n: 2,  reverse: false, text: "In the last month, how often have you felt that you were unable to control the important things in your life?" },
    { n: 3,  reverse: false, text: "In the last month, how often have you felt nervous and stressed?" },
    { n: 4,  reverse: true,  text: "In the last month, how often have you felt confident about your ability to handle your personal problems?" },
    { n: 5,  reverse: true,  text: "In the last month, how often have you felt that things were going your way?" },
    { n: 6,  reverse: false, text: "In the last month, how often have you found that you could not cope with all the things that you had to do?" },
    { n: 7,  reverse: true,  text: "In the last month, how often have you been able to control irritations in your life?" },
    { n: 8,  reverse: true,  text: "In the last month, how often have you felt that you were on top of things?" },
    { n: 9,  reverse: false, text: "In the last month, how often have you been angered because of things that were outside of your control?" },
    { n: 10, reverse: false, text: "In the last month, how often have you felt difficulties were piling up so high that you could not overcome them?" }
];
var PSS_STALE_DAYS = 120;   // it asks about the last month; past ~4 months it's history, not status

// answers = array of 10 integers 0-4 (index 0 = item 1). Returns 0-40, or null
// if the response set is incomplete/invalid.
function scorePss10(answers) {
    if (!answers || answers.length !== 10) return null;
    var total = 0;
    for (var i = 0; i < 10; i++) {
        var a = answers[i];
        if (a === null || a === undefined || a < 0 || a > 4) return null;
        total += PSS10_ITEMS[i].reverse ? (4 - a) : a;
    }
    return total;
}
function pssLabel(score) {
    if (score === null || score === undefined) return "Not taken";
    if (score <= 13) return "Low";
    if (score <= 26) return "Moderate";
    return "High";
}
// Current PSS status, honouring staleness (a 6-month-old questionnaire is not
// a statement about now).
function pssStatus(state, nowEpoch) {
    var now = nowEpoch || (Date.now() / 1000);
    var p = state.trackers.pss;
    if (!p || p.score === null || p.score === undefined)
        return { score: null, label: "Not taken", ageDays: null, stale: false, due: true };
    var ageDays = p.date ? Math.round((now - p.date) / DAY_SECONDS) : 0;
    var stale = ageDays > PSS_STALE_DAYS;
    return {
        score: p.score, label: stale ? "Stale" : pssLabel(p.score),
        ageDays: ageDays, stale: stale,
        due: stale || ageDays >= 90            // quarterly cadence
    };
}

// ── AFFECT: Russell's circumplex model (valence × arousal) ─────────────────
// The standard model in affective science: mood is NOT one number. It is a
// point on a 2-D plane —
//     valence  −1 (unpleasant) … +1 (pleasant)
//     arousal  −1 (deactivated) … +1 (activated)
// A single "mood score" collapses these and averages genuinely opposite states
// into a meaningless middle: agitated (low valence, HIGH arousal) and flat /
// depressed (low valence, LOW arousal) are not the same thing, and treating
// them as one number hides exactly the distinction that matters.
//
// SOURCE OF TRUTH: `trackers.affect.observed` — to be fed by the AI layer
// (language valence from self-referential statements; arousal from speech rate,
// message velocity, activity bursts). Until that lands, `affectState()` falls
// back to an ESTIMATE derived from biometrics, and says so via `.source`, so an
// inferred point is never mistaken for an observed one.
var AFFECT_STALE_MIN = 90;   // an observed reading older than this stops being "now"

// Interim estimate — biometric proxies only, no AI feed.
function estimatedValence(state) {
    // Pleasantness proxy: resilience & liveliness lift it, stress pulls it down.
    var res    = resilienceIndex(state) / 100;
    var stress = stressLevel(state) / 100;
    var lively = state.facets.liveliness.score / 100;
    return clamp(2 * (0.40 * res + 0.35 * (1 - stress) + 0.25 * lively) - 1, -1, 1);
}
function estimatedArousal(state) {
    // Activation proxy: heart rate above rest, digital churn and late-night
    // activity all mean "switched on"; sleep debt drags activation down.
    var b = state.trackers.biometrics;
    var hr      = b.rhr > 0 ? clamp((b.rhr - 55) / 30, 0, 1) : 0.5;      // 55→85 bpm
    var churn   = clamp(b.taskSwitches / 200, 0, 1);
    var late    = clamp(b.lateNightMsgs / 10, 0, 1);
    // Caffeine's arousal effect comes straight from the compound model.
    var caffeine= clamp(state.trackers.intake.caffeineMg * COMPOUNDS.caffeine.arousalPerMg, 0, 1);
    var sleepy  = 1 - clamp(b.sleepHours / 8, 0, 1);
    var act = 0.30 * hr + 0.25 * churn + 0.15 * late + 0.20 * caffeine - 0.20 * sleepy;
    return clamp(2 * clamp(act + 0.35, 0, 1) - 1, -1, 1);
}

// The four circumplex quadrants, named as Russell names them.
function affectQuadrant(v, a) {
    if (a >= 0 && v >= 0) return { key: "elated",    name: "Elated",    desc: "activated & pleasant — excited, energised" };
    if (a >= 0 && v <  0) return { key: "agitated",  name: "Agitated",  desc: "activated & unpleasant — stressed, tense" };
    if (a <  0 && v <  0) return { key: "flat",      name: "Flat",      desc: "deactivated & unpleasant — drained, low" };
    return                       { key: "calm",      name: "Calm",      desc: "deactivated & pleasant — relaxed, content" };
}

// Current affect: the observed point if the AI layer has supplied a fresh one,
// otherwise the biometric estimate — always labelled with which.
function affectState(state, nowEpoch) {
    var now = nowEpoch || (Date.now() / 1000);
    var af = state.trackers.affect || {};
    var obs = af.observed;
    if (obs && obs.updated && (now - obs.updated) / 60 <= AFFECT_STALE_MIN
        && obs.valence !== null && obs.arousal !== null) {
        var q0 = affectQuadrant(obs.valence, obs.arousal);
        return { valence: clamp(obs.valence, -1, 1), arousal: clamp(obs.arousal, -1, 1),
                 quadrant: q0.key, name: q0.name, desc: q0.desc,
                 source: "observed", confidence: obs.confidence === undefined ? 1 : obs.confidence,
                 ageMin: Math.round((now - obs.updated) / 60) };
    }
    var v = estimatedValence(state), a = estimatedArousal(state);
    var q = affectQuadrant(v, a);
    return { valence: v, arousal: a, quadrant: q.key, name: q.name, desc: q.desc,
             source: "estimated", confidence: 0.4, ageMin: 0 };
}

// ── EP: ENERGY — activation backed (or not) by physical resources ──────────
// Arousal alone is NOT energy: you can be wired and empty. Real usable energy is
// activation × the resources to sustain it. So EP blends the circumplex arousal
// with what the body actually has in the tank (sleep, resilience, fuel, water).
// When activation runs high on low resources, that's "running on fumes" — a
// borrowed-energy state worth naming rather than scoring as healthy energy.
function energyResources(state) {
    var v = state.vitals;
    var sleepQ = sleepQuality(state) / 100;
    var res    = resilienceIndex(state) / 100;
    var fuel   = v.hpMax > 0 ? clamp(v.hp / v.hpMax, 0, 1) : 0;
    var water  = v.ppMax > 0 ? clamp(v.pp / v.ppMax, 0, 1) : 0;
    return clamp(0.35 * sleepQ + 0.25 * res + 0.25 * fuel + 0.15 * water, 0, 1);
}
function energyLevel(state) {
    var af = affectState(state);
    var activation = (af.arousal + 1) / 2;          // −1..1 → 0..1
    var resources  = energyResources(state);
    return Math.round(100 * clamp(0.45 * activation + 0.55 * resources, 0, 1));
}
// Wired but empty: activated well beyond what the body is currently supporting.
function runningOnFumes(state) {
    var af = affectState(state);
    return ((af.arousal + 1) / 2) - energyResources(state) > 0.30;
}
function energyLabel(state) {
    var e = energyLevel(state);
    if (runningOnFumes(state)) return "Running on fumes";
    if (e < 30) return "Depleted";
    if (e < 50) return "Low";
    if (e < 70) return "Steady";
    if (e < 85) return "Strong";
    return "Peak";
}

// ── REACTIVITY → WILLPOWER ─────────────────────────────────────────────────
// Reactivity (0-1) = how much the emotional weather around you moves you: do you
// absorb it, mirror it, escalate it? It belongs to WILLPOWER, not mood, because
// regulating yourself against other people's states is precisely what SPENDS the
// shield. A day of high reactivity means the daily shield renews smaller — you
// already spent that capacity keeping your footing.
// Fed by the AI layer (their tone vs your response); defaults to 0 (unmeasured
// ⇒ no penalty, never a fabricated one).
function reactivityOf(state) {
    var af = state.trackers.affect || {};
    return clamp(af.reactivity === undefined || af.reactivity === null ? 0 : af.reactivity, 0, 1);
}
function reactivityLabel(r) {
    if (r <= 0)    return "Unmeasured";
    if (r < 0.25)  return "Regulated";
    if (r < 0.50)  return "Responsive";
    if (r < 0.75)  return "Reactive";
    return "Highly reactive";
}
// Reactivity is now paid out of FOCUS (see dailyReset) — a day of absorbing
// other people's emotional weather costs you focus you'd otherwise have kept.
function reactivityFpTax(state) {
    return Math.round(REACTIVITY_FP_TAX * reactivityOf(state));
}

// ── Derived affective / recovery signals ───────────────────────────────────
// Sleep quality (0-100): duration + architecture (deep+REM) + short latency.
function sleepQuality(state) {
    var b = state.trackers.biometrics;
    var dur  = clamp(b.sleepHours / 8, 0, 1);
    var arch = clamp((b.deepPct + b.remPct) / 45, 0, 1);
    var lat  = 1 - clamp(b.sleepLatencyMin / 60, 0, 1);
    return Math.round(100 * (0.4 * dur + 0.4 * arch + 0.2 * lat));
}
// Stress (0-100, higher = worse): HRV strain vs baseline + trait anxiety +
// digital friction + sleep debt.
function stressLevel(state) {
    var b = state.trackers.biometrics;
    var hrvStrain = b.hrvBaseline > 0 ? clamp(1 - b.hrv / b.hrvBaseline, 0, 1) : 0;
    var anx       = clamp(state.facets.anxiety.score / 100, 0, 1);
    var digital   = clamp(b.screenMin / 600, 0, 1);
    var sleepDebt = 1 - clamp(b.sleepHours / 8, 0, 1);
    return Math.round(100 * clamp(0.35 * hrvStrain + 0.30 * anx + 0.20 * digital + 0.15 * sleepDebt, 0, 1));
}
// Mood (0-100, higher = better): resilience + low stress + liveliness warmth.
function moodScore(state) {
    var res       = resilienceIndex(state) / 100;
    var stress    = stressLevel(state) / 100;
    var liveliness = clamp(state.facets.liveliness.score / 100, 0, 1);
    return Math.round(100 * clamp(0.40 * res + 0.35 * (1 - stress) + 0.25 * liveliness, 0, 1));
}
function stressLabel(v) { return v > 65 ? "High" : v > 35 ? "Moderate" : "Low"; }
function moodLabel(v)   { return v < 40 ? "Low"  : v < 65 ? "Neutral"  : "Good"; }

// Vein state per muscle group, from days-since-last-trained:
//   0 (trained today)   → "pump"     (show, red, at today's intensity)
//   1 (day after)       → "recovery" (show, blue)
//   ≥2 (missed a day)   → "rested"   (hidden)
function veinState(state, group) {
    var m = state.trackers.movement;
    var days  = group === "arms" ? m.armsDaysSince : m.legsDaysSince;
    var pump  = group === "arms" ? m.armsWorked   : m.legsWorked;
    if (days <= 0 && pump > 0) return { show: true,  mode: "pump",     intensity: pump };
    if (days === 1)           return { show: true,  mode: "recovery", intensity: 0.55 };
    return { show: false, mode: "rested", intensity: 0 };
}

// Which muscle groups today's training hit (drives the "popping veins").
function workoutFocusLabel(state) {
    var m = state.trackers.movement;
    var a = m.armsWorked > 0.4, l = m.legsWorked > 0.4;
    if (a && l) return "full body";
    if (a) return "arms";
    if (l) return "legs";
    if (m.workouts > 0 || m.activeMin > 20) return "cardio";
    return "rest day";
}

// ── Full status summary: one synthesis over biometrics, trackers, vitals AND
// the HEXACO personality / danger-zone state. Returns a short multi-sentence
// human-readable string. ────────────────────────────────────────────────────
function lifeSummary(state) {
    var dims = ["H", "E", "X", "A", "C", "O"], best = null, bestLvl = -1;
    for (var i = 0; i < dims.length; i++) {
        var d = dimensionSummary(state, dims[i]);
        if (d.level > bestLvl) { bestLvl = d.level; best = d; }
    }
    var dz = computeDangerZones(state);
    var sq = sleepQuality(state), stress = stressLevel(state), mood = moodScore(state), res = resilienceIndex(state);
    var b = state.trackers.biometrics, v = state.vitals;
    var parts = [];

    var sleepDesc = sq < 45 ? "poor sleep" : sq < 70 ? "so-so sleep" : "solid sleep";
    parts.push("Running on " + sleepDesc + " (" + b.sleepHours + "h, Q" + sq + ") with "
        + stressLabel(stress).toLowerCase() + " stress; resilience " + res + ", mood " + moodLabel(mood).toLowerCase() + ".");

    var s2 = (best ? best.name + " is the anchor (Lv." + best.level + ")" : "");
    if (dz.length) s2 += (s2 ? ", but " : "") + dz.length + " danger zone" + (dz.length === 1 ? "" : "s")
        + " active: " + dz.map(function (z) { return z.name; }).join(", ");
    if (s2) parts.push(s2 + ".");

    var behind = [];
    if (v.hpMax > 0 && v.hp / v.hpMax < 0.55) behind.push("calories");
    if (state.trackers.intake.waterMl < dailyWaterTarget(state) * 0.6) behind.push("hydration");
    if (movementScore(state) < 0.6) behind.push("movement");
    if (state.trackers.nutrition.meals < state.trackers.nutrition.mealTarget) behind.push("meals");
    if (behind.length) parts.push("Behind target: " + behind.join(", ") + ".");

    return parts.join(" ");
}

// ── Empty + mock state factories ───────────────────────────────────────────
function emptyTrackers() {
    return {
        // Objective physiological & environmental proxies.
        biometrics: {
            sleepHours: 0, deepPct: 0, remPct: 0, sleepLatencyMin: 0,
            rhr: 0, hrv: 0, hrvBaseline: 0,
            screenMin: 0, lateNightMsgs: 0, taskSwitches: 0
        },
        // Explicit lifestyle trackers.
        // Everything you drank today, resolved to ACTIVE COMPOUNDS. Drinks are
        // just compositions of these (see DRINK_PRESETS / drink()), so effects
        // fall out of the pharmacology rather than a per-beverage rule table.
        intake: emptyIntake(),
        environment: { tempC: 21, humidity: 50 },              // today's high + humidity (fed from the weather cache)
        // Allostatic-load biomarkers you supply (blood panel + home measurements).
        // Each is { value, date } with date = UNIX SECONDS of the measurement;
        // stale entries (labs >1y, home >90d) are treated as UNMEASURED, never as
        // "fine". Fed from labs.json — see allostaticLoad().
        labs: {},
        // PSS-10 quarterly check-in: { score: 0-40, date: epoch } — fed from pss.json.
        pss: { score: null, date: null },
        // Russell circumplex + reactivity. `observed` is the seam for the AI
        // layer (valence/arousal −1..1, confidence 0-1, updated = epoch); when
        // absent or stale, affectState() falls back to a biometric ESTIMATE and
        // labels it as such. `reactivity` (0-1) taxes the willpower shield.
        affect: { observed: null, reactivity: 0 },
        // calories = ALL kcal today, food AND drink (drink() folds liquid calories
        // in). drinkCalories tracks the liquid share so it can't hide. quality 0-100.
        nutrition: { calories: 0, drinkCalories: 0, protein: 0, carbs: 0, fat: 0, meals: 0, mealTarget: 3, quality: 0 },
        // Today's medication doses, keyed by POTION_DEFS key → amount in that
        // potion's unit (e.g. { ibuprofen: 400, nyquil: 30 }). Fed by foodlog.json.
        meds: {},
        // *Target fields are placeholders — syncVitalsFromTrackers overwrites
        // them from dailyExerciseTargets() (profile age + goal).
        // Last night's hypnogram (see sleepSession). Empty → no graph on EP.
        sleep: { screensOff: "", bedtime: "", segments: [] },
        // zone2Min: real HR-derived minutes in Zone 2. null → fall back to the
        // activeMin guess (see zone2Today).
        movement:  { steps: 0, stepTarget: 9000, activeMin: 0, activeTarget: 25, workouts: 0, workoutTarget: 1,
                     zone2Min: null, zone2Target: 60,
                     workoutLog: [],
                     armsWorked: 0, legsWorked: 0,          // 0-1 "pump" per group, today
                     armsDaysSince: 99, legsDaysSince: 99 },  // days since last trained (0=today, 1=recovery, ≥2=gone)
        dependencies: []                                       // [{ name, count, limit, unit }]
    };
}

function emptyState() {
    var facets = {}, keys = allFacetKeys();
    for (var i = 0; i < keys.length; i++) facets[keys[i]] = { xp: 0, score: 50, pendingDecay: 0 };
    return {
        facets: facets,
        // hp/hpMax (kcal), pp/ppMax (ml) and ap/apMax (minutes of Zone 2) are
        // recomputed by syncVitalsFromTrackers from the daily targets; mp (energy)
        // and ep (sleep) are 0-100 readouts; placeholders here.
        // fp is PERSISTENT (never auto-refilled) — a fresh character starts mid-range.
        vitals: { hp: 0, hpMax: 2000, pp: 0, ppMax: 2500, ap: 0, apMax: 60,
                  mp: 100, mpMax: 100, ep: 100, epMax: 100,
                  sp: 100, spMax: 100, fp: 200, fpMax: FP_MAX },
        trackers: emptyTrackers(),
        isRestModeActive: false,
        fpEarnedToday: 0,
        lastCheckIn: 0, lastDailyReset: 0
    };
}

// Realistic seed: a mid-level character, a couple of danger zones live, a
// visible reframing bonus, a partially-spent shield, decay queued but not yet
// applied, Rest Mode available but off.
function mockState() {
    var st = emptyState();
    function set(k, xp, score, pending) {
        st.facets[k] = { xp: xp, score: score, pendingDecay: pending || 0 };
    }
    // Honesty-Humility — drifting low → Hubris Blindness live.
    set("sincerity", 900, 58);
    set("fairness", 1400, 30);
    set("greed_avoidance", 1100, 44);
    set("modesty", 600, 18);
    // Emotionality — Anxiety Spiral live.
    set("fearfulness", 500, 55);
    set("anxiety", 1300, 86, 96);        // pending decay queued from a rough stretch
    set("dependence", 400, 40);
    set("sentimentality", 700, 62);
    // Extraversion — Sociability pulled back by deep-focus (reframed → Diligence).
    set("social_self_esteem", 1000, 60);
    set("social_boldness", 800, 52);
    set("sociability", 700, 34);
    set("liveliness", 900, 48);
    // Agreeableness — healthy.
    set("forgiveness", 1200, 66);
    set("gentleness", 1000, 58);
    set("flexibility", 800, 40);
    set("patience", 1500, 62);
    // Conscientiousness — strongest suit; Rigidity live (perfectionism high, flexibility low).
    set("organization", 1800, 72);
    set("diligence", 2400, 80);          // boosted, incl. reframing spillover
    set("perfectionism", 2000, 88);
    set("prudence", 1600, 70);
    // Openness — solid.
    set("aesthetic_appreciation", 1100, 64);
    set("inquisitiveness", 1900, 78);
    set("creativity", 1400, 70);
    set("unconventionality", 900, 55);

    st.vitals = { hp: 0, hpMax: 2000, pp: 0, ppMax: 2500, ap: 0, apMax: 60,
                  mp: 70, mpMax: 100, ep: 68, epMax: 100,
                  sp: 60, spMax: 100, fp: 246, fpMax: FP_MAX };
    st.fpEarnedToday = 18;

    // Objective proxies: a mediocre night (HRV sitting below baseline → the
    // Resilience Index reads low, an early warning) and some digital friction.
    st.trackers.biometrics = {
        sleepHours: 6.4, deepPct: 14, remPct: 17, sleepLatencyMin: 34,
        rhr: 62, hrv: 41, hrvBaseline: 55,
        screenMin: 392, lateNightMsgs: 7, taskSwitches: 148
    };
    // Last night, stage by stage (drives the EP hypnogram AND, via
    // syncVitalsFromTrackers, the sleep biometrics above).
    st.trackers.sleep = {
        screensOff: "22:58",   // devices went dark 44 min before bed
        bedtime: "23:42",
        segments: [
            { stage: "awake", min: 14 },   // sleep latency
            { stage: "core",  min: 45 },
            { stage: "deep",  min: 35 },
            { stage: "core",  min: 25 },
            { stage: "rem",   min: 20 },
            { stage: "core",  min: 32 },
            { stage: "deep",  min: 28 },
            { stage: "core",  min: 26 },
            { stage: "rem",   min: 30 },
            { stage: "awake", min: 6  },   // wake-up
            { stage: "core",  min: 30 },
            { stage: "rem",   min: 26 },
            { stage: "core",  min: 22 },
            { stage: "rem",   min: 24 },
            { stage: "awake", min: 4  },   // wake-up
            { stage: "core",  min: 20 }
        ]
    };
    // Lifestyle trackers.
    st.trackers.intake = emptyIntake();
    st.trackers.environment = { tempC: 27, humidity: 40 };   // warm mock day → visible heat bonus
    // 1450 kcal from FOOD; drink() will add the liquid calories on top.
    st.trackers.nutrition = { calories: 1450, drinkCalories: 0, protein: 92, carbs: 165, fat: 48, meals: 2, mealTarget: 3, quality: 58 };
    st.trackers.meds = { ibuprofen: 400 };   // one dose today — shows as a potion
    // Per-meal log (Breakfast / Lunch / Dinner) — the pipeline overwrites this;
    // an empty items list renders as "not logged yet".
    st.mealLog = {
        breakfast: { items: ["Oats, banana & peanut butter", "Black coffee"], kcal: 430 },
        lunch:     { items: ["Chicken & rice bowl", "Greek yogurt"],           kcal: 620 },
        dinner:    { items: [],                                                kcal: 0   },
        snacks:    { items: ["Protein bar", "Beer"],                           kcal: 400 }
    };
    st.trackers.movement  = { steps: 6800, stepTarget: 9000, activeMin: 28, activeTarget: 45, workouts: 1, workoutTarget: 1,
                               zone2Min: 34, zone2Target: 60,
                               workoutLog: [
                                   { name: "Push Day", minutes: 62, exercises: [
                                       { name: "Bench Press", sets: [ { kg: 60, reps: 10 }, { kg: 70, reps: 8 }, { kg: 75, reps: 6, pr: true } ] },
                                       { name: "Overhead Press", sets: [ { kg: 40, reps: 10 }, { kg: 45, reps: 8 } ] },
                                       { name: "Cable Fly", sets: [ { kg: 20, reps: 12 }, { kg: 20, reps: 12 } ] }
                                   ] },
                                   { name: "Zone-2 Run", minutes: 42, exercises: [
                                       { name: "Treadmill", cardio: { minutes: 42, km: 6.4, avgHr: 146 } }
                                   ] }
                               ],
                               armsWorked: 0.9, legsWorked: 0,          // trained arms today
                               armsDaysSince: 0, legsDaysSince: 1 };    // arms=today (red), legs=recovery (blue)
    // Mock affect: no AI feed yet, so leave `observed` null — affectState()
    // will derive an estimate and label it "estimated". A mid reactivity so the
    // shield-tax path is visible.
    st.trackers.affect = { observed: null, reactivity: 0.45 };
    st.trackers.dependencies = [
        { name: "Caffeine", count: 0,   limit: 3, unit: "×150mg" },
        { name: "Nicotine", count: 5,   limit: 4, unit: "" },
        { name: "Alcohol",  count: 0,   limit: 2, unit: "" },
        { name: "Screens",  count: 6.5, limit: 5, unit: "h" }
    ];
    // Today's drinks. Each resolves to compounds — hydration, caffeine, ethanol
    // and sugar all fall out of the composition, no per-drink rules.
    drink(st, "coffee", 2);
    drink(st, "water", 2);
    drink(st, "beer", 1);

    // MP/AP/EP/SP (Hydration/Exercise/Motivation/Soul) are readouts of the trackers above — derive
    // them so the gauges are consistent with the seeded sleep/movement data.
    syncVitalsFromTrackers(st);

    st.isRestModeActive = false;
    return st;
}
