.pragma library

// ─────────────────────────────────────────────────────────────────────────
// Life-OS state machine: a HEXACO personality model rendered as a
// psychologically-safe RPG progression engine. Pure functions over a plain
// state object — no QML/UI here, so it's unit-testable with node (see the
// standalone tests) and the UI layer just reads its outputs.
//
// Guardrails baked in (all from the design brief):
//   • Willpower Shield (WS): a daily-renewable buffer. Negative deltas hit WS
//     FIRST; permanent XP is only ever threatened by the OVERFLOW past a fully
//     depleted shield.
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
// everything else (a bad stretch still hits the Willpower Shield first, never
// instant permanent loss). This is where "altruism feeds the personality part"
// is made literal — mapped to the facets it actually expresses through.
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
    self_directed_boundary: [ { facet: "prudence", sign: +1 }, { facet: "social_self_esteem", sign: +1 } ]
};

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
        // Willpower Shield absorbs first.
        var absorbed = Math.min(state.vitals.ws, mag);
        state.vitals.ws -= absorbed;
        var overflow = mag - absorbed;
        res.absorbed = absorbed;
        res.overflow = overflow;

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
    return results;
}

// ── Scheduled check-in: the ONLY place permanent XP can actually drop ──────
// Compiles every facet's accumulated pendingDecay into real XP loss. Frozen
// during Rest Mode. Returns per-facet applied losses (for a summary UI).
var HP_DECAY_SCALE = 0.03;   // how much of the compiled XP loss also wears down HP
function runCheckIn(state, nowEpoch) {
    if (state.isRestModeActive) return { frozen: true, losses: {} };
    var losses = {}, totalApplied = 0;
    var keys = allFacetKeys();
    for (var i = 0; i < keys.length; i++) {
        var f = state.facets[keys[i]];
        if (f.pendingDecay > 0) {
            var applied = Math.min(f.xp, f.pendingDecay);
            f.xp -= applied;
            losses[keys[i]] = applied;
            totalApplied += applied;
        }
        f.pendingDecay = 0;
    }
    // HP (Vitality) is the recoverable "core condition" gauge — it too is only
    // ever worn down HERE, at the deferred check-in, never instantly by a bad
    // moment (same anti-punitive rule as permanent XP). It regenerates daily.
    var hpLoss = Math.round(totalApplied * HP_DECAY_SCALE);
    state.vitals.hp = Math.max(0, state.vitals.hp - hpLoss);
    state.lastCheckIn = nowEpoch || state.lastCheckIn;
    return { frozen: false, losses: losses, hpLoss: hpLoss };
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
    state.vitals.ws = state.vitals.wsMax;   // shield fully renews each day
    // MP (Focus) and AP (Movement) are pure readouts of today's tracked sleep &
    // physical activity — recompute rather than blindly refill.
    syncVitalsFromTrackers(state);
    // HP (Vitality) is the deeper resource: it recovers only PARTIALLY per day,
    // and that recovery is FOOD-GATED — a well-fed, hydrated day restores the
    // full increment, a poorly-fed one restores little. Sustained strain shows
    // up as a slowly-draining core condition a single good night won't undo.
    var hpGain = Math.round(state.vitals.hpMax * 0.2 * nutritionScore(state));
    state.vitals.hp = Math.min(state.vitals.hpMax, state.vitals.hp + hpGain);
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
// Each of the four vital gauges is the live readout of a real tracked domain:
//   HP (Vitality)  ← nutrition + hydration      (how you fuel the body)
//   MP (Focus)     ← sleep architecture − digital friction   (mental energy)
//   AP (Movement)  ← steps + active minutes + workouts        (physical output)
//   WS (Willpower) ← daily-renewable buffer, modulated by resilience
// The three "supply" scores below are 0-1 and drive both the gauge value and
// the breakdown shown on each vital's detail page.
function nutritionScore(state) {
    var n = state.trackers.nutrition, h = state.trackers.hydration;
    var meals = clamp(n.meals / Math.max(1, n.mealTarget), 0, 1);
    var qual  = clamp(n.quality / 100, 0, 1);
    var hyd   = clamp(h.cups / Math.max(1, h.target), 0, 1);
    return clamp(0.4 * meals + 0.4 * qual + 0.2 * hyd, 0, 1);
}
function movementScore(state) {
    var m = state.trackers.movement;
    var steps = clamp(m.steps / Math.max(1, m.stepTarget), 0, 1);
    var act   = clamp(m.activeMin / Math.max(1, m.activeTarget), 0, 1);
    var wk    = clamp(m.workouts / Math.max(1, m.workoutTarget), 0, 1);
    return clamp(0.4 * steps + 0.3 * act + 0.3 * wk, 0, 1);
}
function focusScore(state) {
    var b = state.trackers.biometrics;
    var sleep   = clamp(b.sleepHours / 8, 0, 1);
    var arch    = clamp((b.deepPct + b.remPct) / 45, 0, 1);
    var digital = 1 - clamp(b.screenMin / 600, 0, 1);   // more screen ⇒ less focus
    return clamp(0.4 * sleep + 0.3 * arch + 0.3 * digital, 0, 1);
}

// Recompute the derived gauges from today's tracked inputs. MP & AP are pure
// readouts of Focus/Movement; HP is food-gated but "sticky" (only topped up,
// never overwritten, so a strong body isn't erased by one bad meal-day); WS is
// left to the daily-reset / shield mechanic.
function syncVitalsFromTrackers(state) {
    state.vitals.mp = Math.round(state.vitals.mpMax * focusScore(state));
    state.vitals.ap = Math.round(state.vitals.apMax * movementScore(state));
    return state;
}

// Static metadata for each vital's detail page.
var VITAL_INFO = {
    hp: { key: "hp", label: "HP", name: "Vitality",  glyph: "", accent: "red",
          tagline: "Your physical baseline — built by how you eat and hydrate." },
    mp: { key: "mp", label: "MP", name: "Focus",     glyph: "", accent: "blue",
          tagline: "Mental energy for deep work — set by sleep quality, drained by digital friction." },
    ap: { key: "ap", label: "AP", name: "Movement",  glyph: "", accent: "yellow",
          tagline: "Physical output & momentum — built by working out and moving your body." },
    ws: { key: "ws", label: "WS", name: "Willpower", glyph: "", accent: "teal",
          tagline: "A daily-renewable shield that absorbs setbacks before they touch permanent progress." }
};
function vitalInfo(key) { return VITAL_INFO[key] || null; }

// The contributing-input breakdown shown on a vital's detail page.
function vitalBreakdown(state, key) {
    var t = state.trackers;
    if (key === "hp") {
        var n = t.nutrition, h = t.hydration;
        return [
            { label: "Meals",     ratio: n.meals / Math.max(1, n.mealTarget), valueText: n.meals + " / " + n.mealTarget },
            { label: "Nutrition", ratio: n.quality / 100,                      valueText: "Q" + n.quality },
            { label: "Hydration", ratio: h.cups / Math.max(1, h.target),       valueText: h.cups + " / " + h.target + " cups" }
        ];
    }
    if (key === "ap") {
        var m = t.movement;
        return [
            { label: "Steps",    ratio: m.steps / Math.max(1, m.stepTarget),        valueText: m.steps + " / " + m.stepTarget },
            { label: "Active",   ratio: m.activeMin / Math.max(1, m.activeTarget),  valueText: m.activeMin + " / " + m.activeTarget + " min" },
            { label: "Workouts", ratio: m.workouts / Math.max(1, m.workoutTarget),  valueText: m.workouts + " / " + m.workoutTarget }
        ];
    }
    if (key === "mp") {
        var b = t.biometrics;
        return [
            { label: "Sleep",    ratio: b.sleepHours / 8,               valueText: b.sleepHours + " h" },
            { label: "Deep+REM", ratio: (b.deepPct + b.remPct) / 45,    valueText: (b.deepPct + b.remPct) + "%" },
            { label: "Low friction", ratio: 1 - clamp(b.screenMin / 600, 0, 1), valueText: Math.round(b.screenMin / 60) + "h screen" }
        ];
    }
    if (key === "ws") {
        return [
            { label: "Shield",     ratio: state.vitals.ws / state.vitals.wsMax, valueText: state.vitals.ws + " / " + state.vitals.wsMax },
            { label: "Resilience", ratio: resilienceIndex(state) / 100,         valueText: resilienceIndex(state) + " / 100" }
        ];
    }
    return [];
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
    if (v.hp < 55) behind.push("vitality");
    if (state.trackers.hydration.cups < state.trackers.hydration.target * 0.6) behind.push("hydration");
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
        hydration: { cups: 0, target: 8 },
        nutrition: { meals: 0, mealTarget: 3, quality: 0 },    // quality 0-100
        movement:  { steps: 0, stepTarget: 9000, activeMin: 0, activeTarget: 45, workouts: 0, workoutTarget: 1,
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
        vitals: { hp: 100, hpMax: 100, mp: 100, mpMax: 100, ap: 60, apMax: 60, ws: 100, wsMax: 100 },
        trackers: emptyTrackers(),
        isRestModeActive: false,
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

    st.vitals = { hp: 84, hpMax: 100, mp: 62, mpMax: 100, ap: 41, apMax: 60, ws: 55, wsMax: 100 };

    // Objective proxies: a mediocre night (HRV sitting below baseline → the
    // Resilience Index reads low, an early warning) and some digital friction.
    st.trackers.biometrics = {
        sleepHours: 6.4, deepPct: 14, remPct: 17, sleepLatencyMin: 34,
        rhr: 62, hrv: 41, hrvBaseline: 55,
        screenMin: 392, lateNightMsgs: 7, taskSwitches: 148
    };
    // Lifestyle trackers.
    st.trackers.hydration = { cups: 4, target: 8 };
    st.trackers.nutrition = { meals: 2, mealTarget: 3, quality: 58 };
    st.trackers.movement  = { steps: 6800, stepTarget: 9000, activeMin: 28, activeTarget: 45, workouts: 1, workoutTarget: 1,
                               armsWorked: 0.9, legsWorked: 0,          // trained arms today
                               armsDaysSince: 0, legsDaysSince: 1 };    // arms=today (red), legs=recovery (blue)
    st.trackers.dependencies = [
        { name: "Caffeine", count: 3,   limit: 3, unit: "cups" },
        { name: "Nicotine", count: 5,   limit: 4, unit: "" },
        { name: "Alcohol",  count: 0,   limit: 2, unit: "" },
        { name: "Screens",  count: 6.5, limit: 5, unit: "h" }
    ];

    // MP (Focus) & AP (Movement) are readouts of the trackers above — derive
    // them so the gauges are consistent with the seeded sleep/movement data.
    syncVitalsFromTrackers(st);

    st.isRestModeActive = false;
    return st;
}
