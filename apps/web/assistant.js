// Reads what a passenger types into names and flags, matches the names to the
// saved map, and turns them into route constraints. A port of the iOS app's
// AI/StationMatcher.swift, AI/PassengerTurn.swift and AI/RerouteAssistant.swift;
// keep them in step. A model (Gemini, or Chrome's on-device model through
// Firebase AI Logic) may read the message, but only this file decides which
// station a name means, and nothing the passenger didn't say gets through.

// MARK: - Text

export function normalise(text) {
  return String(text).normalize("NFD").replace(/[̀-ͯ]/g, "").toLowerCase()
    .replace(/&/g, " and ").replace(/[’']/g, "").replace(/[^a-z0-9]+/g, " ").trim().replace(/\s+/g, " ");
}

/** "warren st" → "warren street", but "st pauls" stays (Saint). */
export function expandStreet(text) {
  const connectors = new Set(["station", "to", "and", "on", "via", "from", "at", "for", "now", "but", "is"]);
  const words = text.split(" ").filter(Boolean);
  for (let i = 1; i < words.length; i++) {
    if (words[i] === "st" && (i + 1 >= words.length || connectors.has(words[i + 1]))) words[i] = "street";
  }
  return words.map(w => (w === "rd" ? "road" : w)).join(" ");
}

export function editDistance(a, b) {
  if (!a.length) return b.length;
  if (!b.length) return a.length;
  let previous = Array.from({ length: b.length + 1 }, (_, i) => i);
  for (let i = 1; i <= a.length; i++) {
    const current = [i];
    for (let j = 1; j <= b.length; j++) {
      current[j] = Math.min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1));
    }
    previous = current;
  }
  return previous[b.length];
}

const sameWords = (a, b) => a.length === b.length && a.every((w, i) => w === b[i]);

// MARK: - Station matcher

const ALIASES = {
  "kings x": "kings cross st pancras", kx: "kings cross st pancras", "st pancras": "kings cross st pancras",
  tcr: "tottenham court road", "high st kensington": "high street kensington", "ally pally": "alexandra palace",
  olympia: "kensington olympia"
};
const WEAK_FIRST_WORDS = new Set(["north", "south", "east", "west", "great", "high", "green", "royal", "white", "upper", "queens",
  "regents", "turnham", "golders", "elephant", "tower", "russell", "covent", "goldhawk", "manor", "london", "station"]);
const LINE_ALIASES = {
  "h and c": "hammersmith-city", "hammersmith and city": "hammersmith-city", "w and c": "waterloo-city",
  "waterloo and city": "waterloo-city", drain: "waterloo-city", met: "metropolitan", picc: "piccadilly"
};

export function createMatcher(graph) {
  const keys = graph.sorted.map(s => ({ id: s.id, full: normalise(s.name), base: normalise(s.name.replace(/\s*\(.*\)/, "")) }));
  const lineKeys = [...graph.lineNames].map(([id, name]) => ({ id, key: normalise(name) }));

  // Every way a station can be written, longest first, for scanning free text.
  const byName = new Map();
  for (const k of keys) {
    byName.set(k.full, [...(byName.get(k.full) || []), k.id]);
    if (k.base !== k.full) byName.set(k.base, [...(byName.get(k.base) || []), k.id]);
  }
  const candidates = [...byName].map(([name, ids]) => ({ ids: [...new Set(ids)].sort(), words: name.split(" ") }));
  for (const [alias, target] of Object.entries(ALIASES)) if (byName.has(target)) candidates.push({ ids: byName.get(target), words: alias.split(" ") });
  const lineWords = new Set(lineKeys.flatMap(l => l.key.split(" ")));
  const firstWords = new Map();
  for (const k of keys.filter(k => k.full.includes(" "))) {
    const word = k.full.split(" ")[0];
    firstWords.set(word, [...(firstWords.get(word) || []), k]);
  }
  for (const [word, group] of firstWords) {
    if (group.length === 1 && word.length >= 5 && !byName.has(word) && !lineWords.has(word) && !WEAK_FIRST_WORDS.has(word)) {
      candidates.push({ ids: [group[0].id], words: [word] });
    }
  }
  candidates.sort((a, b) => b.words.length - a.words.length);

  function match(raw, preferLine = null) {
    let name = normalise(raw);
    for (const suffix of [" underground station", " tube station", " station", " underground", " tube"]) {
      if (name.endsWith(suffix)) name = name.slice(0, -suffix.length);
    }
    if (name.startsWith("the ")) name = name.slice(4);
    name = expandStreet(name);
    if (!name) return { kind: "unknown", suggestions: [] };
    if (ALIASES[name]) name = ALIASES[name];

    const pick = ids => {
      if (!ids.length) return null;
      if (ids.length === 1) return { kind: "station", id: ids[0] };
      if (preferLine) {
        const onLine = ids.filter(id => graph.stations.get(id)?.lineIds.includes(preferLine));
        if (onLine.length === 1) return { kind: "station", id: onLine[0] };
      }
      return { kind: "ambiguous", ids };
    };
    const exact = pick(keys.filter(k => k.full === name).map(k => k.id));
    if (exact) return exact;
    const base = pick(keys.filter(k => k.base === name).map(k => k.id));
    if (base) return base;
    const words = name.split(" ");
    const prefix = pick(keys.filter(k => sameWords(k.full.split(" ").slice(0, words.length), words)).map(k => k.id));
    if (prefix) return prefix;
    const scored = keys.map(k => [k.id, Math.min(editDistance(name, k.full), editDistance(name, k.base))]).sort((a, b) => a[1] - b[1]);
    const tolerance = name.length >= 9 ? 2 : name.length >= 5 ? 1 : 0;
    if (scored[0] && scored[0][1] <= tolerance) {
      const typo = pick(scored.filter(s => s[1] === scored[0][1]).map(s => s[0]));
      if (typo) return typo;
    }
    return { kind: "unknown", suggestions: scored.slice(0, 3).filter(s => s[1] <= Math.max(3, Math.floor(name.length / 2))).map(s => s[0]) };
  }

  /** Station names in free text with their word ranges. "Bank branch" is the branch. */
  function mentions(text) {
    const words = expandStreet(normalise(text)).split(" ").filter(Boolean);
    const found = [];
    const taken = new Set();
    for (const c of candidates) {
      if (!c.words.length || c.words.length > words.length) continue;
      for (let start = 0; start + c.words.length <= words.length; start++) {
        const end = start + c.words.length;
        if (!sameWords(words.slice(start, end), c.words)) continue;
        if ([...Array(c.words.length).keys()].some(i => taken.has(start + i))) continue;
        const next = words[end];
        if (next === "branch" || next === "line") continue;
        if (next === "and" && words[end + 1] === "city") continue;
        found.push({ ids: c.ids, start, end });
        for (let i = start; i < end; i++) taken.add(i);
      }
    }
    return found.sort((a, b) => a.start - b.start);
  }

  function line(raw) {
    let name = normalise(raw);
    if (name.startsWith("the ")) name = name.slice(4);
    if (name.endsWith(" line")) name = name.slice(0, -5);
    if (LINE_ALIASES[name]) return LINE_ALIASES[name];
    return lineKeys.find(l => l.key === name)?.id ?? lineKeys.find(l => name.length >= 5 && editDistance(l.key, name) <= 1)?.id ?? null;
  }

  /** Lines named in free text. A bare "Victoria" counts only before "line". */
  function lineMentions(text, stations = []) {
    const words = normalise(text).split(" ").filter(Boolean);
    const names = [...lineKeys.map(l => [l.id, l.key.split(" ")]), ...Object.entries(LINE_ALIASES).map(([k, v]) => [v, k.split(" ")])]
      .sort((a, b) => b[1].length - a[1].length);
    const taken = new Set(stations.flatMap(m => Array.from({ length: m.end - m.start }, (_, i) => m.start + i)));
    const found = [];
    for (const [id, nameWords] of names) {
      for (let start = 0; start + nameWords.length <= words.length; start++) {
        const end = start + nameWords.length;
        if (!sameWords(words.slice(start, end), nameWords)) continue;
        if ([...Array(nameWords.length).keys()].some(i => taken.has(start + i))) continue;
        const next = words[end];
        const isAlsoStation = keys.some(k => k.base === nameWords.join(" "));
        if (!(next === "line" || next === "lines" || !isAlsoStation)) continue;
        found.push({ lineId: id, start, end });
        for (let i = start; i < end; i++) taken.add(i);
      }
    }
    return found.sort((a, b) => a.start - b.start);
  }

  return { graph, match, mentions, line, lineMentions };
}

// MARK: - Parsed turn

export const emptyTurn = () => ({
  currentStation: null, destination: null, line: null, situation: null, trainMoving: false,
  closedLines: [], closedSections: [], closedStations: [], currentRouteBlocked: false,
  stepFree: null, walking: null, fewerChanges: false, asksForUnavailableInfo: false, unassignedStation: null
});

/** The model's reading wins on names; flags and lists from either side are kept. */
export function mergeTurns(model, keywords) {
  return {
    currentStation: model.currentStation ?? keywords.currentStation,
    destination: model.destination ?? keywords.destination,
    line: model.line ?? keywords.line,
    situation: model.situation ?? keywords.situation,
    trainMoving: model.trainMoving || keywords.trainMoving,
    closedLines: [...new Set([...model.closedLines, ...keywords.closedLines])].sort(),
    closedSections: model.closedSections.length ? model.closedSections : keywords.closedSections,
    closedStations: [...new Set([...model.closedStations, ...keywords.closedStations])].sort(),
    currentRouteBlocked: model.currentRouteBlocked || keywords.currentRouteBlocked,
    stepFree: model.stepFree ?? keywords.stepFree,
    walking: model.walking ?? keywords.walking,
    fewerChanges: model.fewerChanges || keywords.fewerChanges,
    asksForUnavailableInfo: model.asksForUnavailableInfo || keywords.asksForUnavailableInfo,
    unassignedStation: model.unassignedStation ?? keywords.unassignedStation
  };
}

// MARK: - Keyword rules

const CLOSURE_WORDS = ["closed", "not running", "isnt running", "arent running", "no service", "no trains",
  "suspended", "shut", "part closure", "out of service", "not working"];

export function keywordParse(text, matcher) {
  const normal = expandStreet(normalise(text));
  const words = normal.split(" ").filter(Boolean);
  const turn = emptyTurn();
  const has = phrase => ` ${normal} `.includes(` ${phrase} `);
  const hasAny = phrases => phrases.some(has);
  const reportsClosure = hasAny(CLOSURE_WORDS);

  if (hasAny(["held", "stuck", "stopped", "not moving", "isnt moving", "standing", "sat at", "sitting at"])) turn.situation = "held";
  if (normal.includes("terminat") || hasAny(["kicked off", "everyone off", "all change", "last stop"])) turn.situation = "terminating";
  if (hasAny(["missed my stop", "missed the stop", "went past", "missed it", "missed my station"])) turn.situation = "missedStop";
  if (hasAny(["moving again", "moving now", "train is moving", "started moving", "going again", "on the move"])) {
    turn.trainMoving = true;
    if (turn.situation === "held") turn.situation = null;
  }
  if (hasAny(["step free", "stepfree", "lift", "lifts", "wheelchair", "pushchair", "buggy", "pram", "no stairs", "without stairs", "no steps", "without steps", "cant do stairs", "no escalators"])) turn.stepFree = true;
  if (hasAny(["no walking", "no walk", "dont want to walk", "cant walk", "not walking", "rather not walk"])) turn.walking = false;
  else if (hasAny(["walk", "walking", "on foot", "id rather walk"])) turn.walking = true;
  if (hasAny(["fewer changes", "fewest changes", "less changes", "no changes", "without changing", "direct", "one train"])) turn.fewerChanges = true;
  if (hasAny(["when will", "how long will", "how long until", "delay", "delays", "is there a service", "status",
    "which platform", "what platform", "platform number", "which exit", "what exit", "live", "next train",
    "is it running", "are they running", "running normally", "good service"])) turn.asksForUnavailableInfo = true;

  const mentions = matcher.mentions(text);
  const lines = matcher.lineMentions(text, mentions);
  const name = m => words.slice(m.start, m.end).join(" ");
  const consumed = new Set();

  if (reportsClosure && words.includes("between")) {
    const between = words.indexOf("between");
    const pair = mentions.filter(m => m.start > between).slice(0, 2);
    if (pair.length === 2) {
      const lineName = lines[0] ? words.slice(lines[0].start, lines[0].end).join(" ") : null;
      turn.closedSections.push({ line: lineName, from: name(pair[0]), to: name(pair[1]) });
      pair.forEach(m => consumed.add(m.start));
    }
  }

  for (const m of mentions) {
    if (consumed.has(m.start)) continue;
    const cue = words.slice(Math.max(0, m.start - 3), m.start);
    const last = cue.at(-1) ?? "";
    const nextWords = words.slice(m.end, m.end + 4).join(" ");
    const lastTwo = cue.slice(-2).join(" ");
    const closedHere = CLOSURE_WORDS.some(w => nextWords.startsWith(w) || nextWords.startsWith(`is ${w}`) || nextWords.startsWith(`station is ${w}`))
      || last === "avoid" || last === "avoiding" || lastTwo === "not via";
    if (closedHere) turn.closedStations.push(name(m));
    else if (last === "towards" || last === "via") continue;
    else if (["at", "from", "in", "reached", "near", "outside"].includes(last)) { if (!turn.currentStation) turn.currentStation = name(m); }
    else if ((["to", "for", "reach", "need", "needs"].includes(last) && lastTwo !== "change to") || cue.includes("going") || cue.includes("heading")) {
      if (!turn.destination) turn.destination = name(m);
    } else if (!turn.unassignedStation) turn.unassignedStation = name(m);
  }
  // "Camden to Warren Street": the first of two names is where they are.
  if (!turn.currentStation && (!turn.destination || turn.unassignedStation) && mentions.length === 2 && !consumed.size
      && !turn.closedStations.length && words.slice(mentions[0].end, mentions[1].start).includes("to")) {
    turn.currentStation = name(mentions[0]);
    turn.destination = name(mentions[1]);
    turn.unassignedStation = null;
  }

  for (const m of lines) {
    const lineName = words.slice(m.start, m.end).join(" ");
    const tail = words.slice(m.end, m.end + 5).join(" ");
    const head = words.slice(Math.max(0, m.start - 3), m.start);
    const closedLine = CLOSURE_WORDS.some(w => tail.includes(w)) || head.includes("avoid") || head.includes("no");
    if (turn.closedSections.some(s => s.line === lineName)) continue;
    if (closedLine && !turn.asksForUnavailableInfo) turn.closedLines.push(lineName);
    else if (head.at(-1) === "to" && head.includes("change")) continue;
    else if (!turn.line && !turn.asksForUnavailableInfo) turn.line = lineName;
  }
  if (reportsClosure && !turn.situation && !turn.closedLines.length && !turn.closedSections.length && !turn.closedStations.length) {
    if (hasAny(["branch", "that way", "that route", "this route", "that line", "this line"])) turn.currentRouteBlocked = true;
    else if (has("line") || has("closed") || has("suspended")) turn.situation = "lineClosed";
  }
  if (hasAny(["cant take that", "cant use that", "that doesnt work", "not that way", "that wont work", "something else", "another way"])) turn.currentRouteBlocked = true;
  return turn;
}

// MARK: - Model readings

/** One JSON Schema for both Gemini and Chrome's on-device model. */
export const MODEL_SCHEMA = {
  type: "object",
  properties: {
    currentStation: { type: "string", description: "Station the passenger is at or stuck at now, copied from their words. Empty if not said." },
    destination: { type: "string", description: "Station the passenger wants to get to, copied from their words. Empty if not said." },
    line: { type: "string", description: "Tube line the passenger is or was on, for example Northern. Empty if not said." },
    situation: { type: "string", enum: ["held", "terminating", "lineClosed", "missedStop", "none"], description: "What happened, if said" },
    trainMoving: { type: "boolean", description: "True only if they say their train is moving again" },
    closedLines: { type: "array", items: { type: "string" }, description: "Tube lines they say are closed, suspended or not running" },
    closedFrom: { type: "string", description: "Station a closed section starts at, for 'between A and B'. Empty if not said." },
    closedTo: { type: "string", description: "Station that closed section ends at. Empty if not said." },
    closedStations: { type: "array", items: { type: "string" }, description: "Stations they say are closed or want to avoid" },
    currentRouteBlocked: { type: "boolean", description: "True if they say the suggested route, that branch or that train can't be used" },
    stepFree: { type: "boolean", description: "True if they need step-free access, lifts, or can't use stairs" },
    walking: { type: "string", enum: ["yes", "no", "unsaid"], description: "yes if happy to walk, no if they don't want to walk" },
    fewerChanges: { type: "boolean", description: "True if they want fewer changes or a direct train" },
    asksForUnavailableInfo: { type: "boolean", description: "True if they ask for live status, delays, when a train will move, platforms or exits" }
  },
  required: ["trainMoving", "closedLines", "closedStations", "currentRouteBlocked", "stepFree", "fewerChanges", "asksForUnavailableInfo"]
};

export const MODEL_INSTRUCTIONS = "You read short messages from London Underground passengers whose journey has gone wrong, often with no signal. "
  + "Fill in only what the passenger actually said. Copy station and line names as they wrote them; do not correct them "
  + "into other stations, and never add stations, lines, closures or delays they did not mention. "
  + "Leave a field empty when they did not say it. You do not plan routes and you do not know live service information.";

export function modelPrompt(text, context = {}) {
  const known = [context.origin && `at ${context.origin}`, context.destination && `going to ${context.destination}`, context.line && `on the ${context.line} line`].filter(Boolean);
  return `${known.length ? `Known so far: ${known.join(", ")}.\n` : ""}${context.currentRoute ? `Route currently suggested: ${context.currentRoute}.\n` : ""}Passenger says: ${text}`;
}

/** A model's JSON reply as a parsed turn. Unknown or empty values become nothing. */
export function turnFromModel(reply) {
  const clean = v => (typeof v === "string" && v.trim() && !["none", "null", "unknown", "n/a", "unsaid"].includes(v.trim().toLowerCase()) ? v.trim() : null);
  const list = v => (Array.isArray(v) ? v.map(clean).filter(Boolean) : []);
  const turn = emptyTurn();
  turn.currentStation = clean(reply.currentStation);
  turn.destination = clean(reply.destination);
  turn.line = clean(reply.line);
  turn.situation = ["held", "terminating", "lineClosed", "missedStop"].includes(reply.situation) ? reply.situation : null;
  turn.trainMoving = reply.trainMoving === true;
  turn.closedLines = list(reply.closedLines);
  const from = clean(reply.closedFrom), to = clean(reply.closedTo);
  if (from && to) {
    turn.closedSections = [{ line: turn.closedLines[0] ?? null, from, to }];
    turn.closedLines = turn.closedLines.filter(l => l !== turn.closedSections[0].line);
  }
  turn.closedStations = list(reply.closedStations);
  turn.currentRouteBlocked = reply.currentRouteBlocked === true;
  turn.stepFree = reply.stepFree === true ? true : null;
  turn.walking = reply.walking === "yes" ? true : reply.walking === "no" ? false : null;
  turn.fewerChanges = reply.fewerChanges === true;
  turn.asksForUnavailableInfo = reply.asksForUnavailableInfo === true;
  return turn;
}

// MARK: - Grounding

const FILLER = new Set(["the", "station", "street", "road", "st", "line", "tube", "underground", "and",
  "park", "lane", "of", "on", "at", "central", "circle", "city", "town"]);

/** Drops any station or line the model "heard" that isn't in the passenger's words. */
export function keepSaid(turn, text, matcher) {
  const said = new Set(normalise(text).split(" "));
  const mentioned = new Set(matcher.mentions(text).flatMap(m => m.ids));
  const grounded = name => {
    if (!name) return false;
    const match = matcher.match(name);
    if (match.kind === "station" && mentioned.has(match.id)) return true;
    const words = normalise(name).split(" ").filter(Boolean);
    const key = words.filter(w => !FILLER.has(w) && w.length >= 3);
    if (!key.length) return words.length > 0 && words.every(w => said.has(w));
    return key.some(word => [...said].some(s => s === word || (word.length >= 5 && editDistance(s, word) <= 1)));
  };
  return {
    ...turn,
    currentStation: grounded(turn.currentStation) ? turn.currentStation : null,
    destination: grounded(turn.destination) ? turn.destination : null,
    line: grounded(turn.line) ? turn.line : null,
    closedLines: turn.closedLines.filter(grounded),
    closedStations: turn.closedStations.filter(grounded),
    closedSections: turn.closedSections.filter(s => grounded(s.from) && grounded(s.to))
  };
}

/** Flags that over-restrict a route are kept only when the words back them up. */
export function reportsClosure(text) {
  const normal = ` ${normalise(text)} `;
  return [...CLOSURE_WORDS, "avoid", "avoiding", "not via", "no", "blocked", "cant use", "not that"].some(w => normal.includes(` ${w} `));
}

const mentionsChanges = text => [" change", " changing", " direct ", " one train "].some(w => ` ${normalise(text)} `.includes(w));

export function trustFlags(turn, keywords, text, matcher = null) {
  turn = { ...turn };
  // Same station however it's written ("Camden", "Camden Town").
  const place = name => { const m = matcher?.match(name); return m?.kind === "station" ? m.id : normalise(name); };
  // No closure words at all: any closure the model reported is its own invention.
  if (!reportsClosure(text)) { turn.closedLines = []; turn.closedStations = []; turn.closedSections = []; }
  const sections = [...turn.closedSections, ...keywords.closedSections];
  const ends = new Set(sections.flatMap(s => [place(s.from), place(s.to)]));
  // Where the passenger is and where they're going aren't closed unless the rules agree.
  const own = new Set([turn.currentStation, turn.destination, keywords.currentStation, keywords.destination].filter(Boolean).map(place));
  const keywordClosed = new Set(keywords.closedStations.map(place));
  const closedStations = turn.closedStations.filter(s => !ends.has(place(s)) && !(own.has(place(s)) && !keywordClosed.has(place(s))));
  // Nor is the line they're on, or a line named in a closed section.
  const onLines = new Set([turn.line, keywords.line, ...sections.map(s => s.line)].filter(Boolean).map(normalise));
  const keywordLines = new Set(keywords.closedLines.map(normalise));
  turn.closedLines = turn.closedLines.filter(l => !(onLines.has(normalise(l)) && !keywordLines.has(normalise(l))));
  turn.fewerChanges = turn.fewerChanges && (keywords.fewerChanges || mentionsChanges(text));
  const explicit = !!(turn.closedSections.length || turn.closedLines.length || closedStations.length);
  const out = { ...turn, closedStations, currentRouteBlocked: turn.currentRouteBlocked && keywords.currentRouteBlocked && !explicit };
  // An explicit closure is more precise than "the line is closed".
  if (out.situation === "lineClosed" && explicit && keywords.situation !== "lineClosed") out.situation = keywords.situation;
  // A closed line isn't also the line the passenger is on.
  const closed = new Set([...turn.closedLines, ...turn.closedSections.map(s => s.line).filter(Boolean)].map(normalise));
  if (out.line && closed.has(normalise(out.line)) && !keywords.line) out.line = null;
  // A live-info question needs the words to back it, and a line named in one isn't the passenger's line.
  out.asksForUnavailableInfo = turn.asksForUnavailableInfo && (keywords.asksForUnavailableInfo || text.includes("?"));
  if (out.asksForUnavailableInfo && !keywords.line) out.line = null;
  return out;
}

/**
 * Keyword rules, plus a model when one is given. `readModel(text, context)`
 * resolves to `{ turn, by }` or throws; it is raced against `timeoutMs`.
 */
export async function interpret(text, context, matcher, readModel = null, timeoutMs = 8000) {
  const keywords = keywordParse(text, matcher);
  // A bare station name ("Euston") answers a question; no model needed.
  if (!readModel || matcher.match(text).kind === "station") return { turn: keywords, by: "keywords" };
  try {
    const result = await Promise.race([
      readModel(text, context),
      new Promise((_, reject) => setTimeout(() => reject(new Error("timeout")), timeoutMs))
    ]);
    const said = keepSaid(result.turn, text, matcher);
    return { turn: mergeTurns(trustFlags(said, keywords, text, matcher), keywords), by: result.by };
  } catch {
    return { turn: keywords, by: "keywords" };
  }
}

// MARK: - Planning

export const SITUATION_NAMES = { held: "Train held", terminating: "Terminating here", lineClosed: "Line closed", missedStop: "Missed my stop" };
const titleCase = s => (s === s.toLowerCase() ? s.replace(/\b\w/g, c => c.toUpperCase()) : s);

/**
 * Resolve a turn against the map. `state` is { origin, destination, onLine,
 * awaiting, currentFirstLeg }. Returns ids, constraints, a question when a
 * name is ambiguous or unknown, and the sentences that say what changed.
 */
export function planTurn(turn, state, matcher) {
  const graph = matcher.graph;
  const name = id => graph.stations.get(id)?.name ?? id;
  const out = {
    origin: null, destination: null, onLine: null, situation: null, trainMoving: false,
    avoidLines: new Set(), avoidSegments: new Set(), avoidStations: new Set(), firstHop: null,
    stepFree: null, walking: null, fewerChanges: false, asksForUnavailableInfo: false,
    question: null, notes: [], problems: [], tags: []
  };
  turn = { ...turn };

  if (turn.unassignedStation) {
    const field = state.awaiting ?? (!state.origin ? "origin" : !state.destination ? "destination" : null);
    if (field === "origin" && !turn.currentStation) turn.currentStation = turn.unassignedStation;
    if (field === "destination" && !turn.destination) turn.destination = turn.unassignedStation;
  }

  if (turn.line) {
    const line = matcher.line(turn.line);
    if (line) { if (line !== state.onLine) { out.onLine = line; out.tags.push(`${graph.lineName(line)} line`); } }
    else out.problems.push(`I couldn’t find a “${turn.line}” line on the saved Tube map.`);
  }
  const preferLine = out.onLine ?? state.onLine;

  const station = (raw, field) => {
    if (!raw) return null;
    const match = matcher.match(raw, preferLine);
    if (match.kind === "station") return match.id;
    if (match.kind === "ambiguous" && !out.question) {
      out.question = { field, prompt: `There’s more than one ${titleCase(raw)} on the map. Which one?`, choices: match.ids };
    }
    if (match.kind === "unknown") {
      out.problems.push(`I couldn’t find “${raw}” on the saved Tube map.`);
      if (!out.question && match.suggestions.length) {
        out.question = { field, prompt: field === "origin" ? "Did you mean one of these?" : "Were you going to one of these?", choices: match.suggestions };
      }
    }
    return null;
  };

  const origin = station(turn.currentStation, "origin");
  if (origin && origin !== state.origin) {
    out.origin = origin; out.tags.push(`At ${name(origin)}`);
    if (state.origin) out.notes.push(`OK, from ${name(origin)}.`);
  }
  const destination = station(turn.destination, "destination");
  if (destination && destination !== state.destination) {
    out.destination = destination; out.tags.push(`To ${name(destination)}`);
    if (state.destination) out.notes.push(`OK, going to ${name(destination)} instead.`);
  }

  if (turn.situation) {
    out.situation = turn.situation;
    out.tags.push(SITUATION_NAMES[turn.situation]);
    if (turn.situation === "lineClosed" && preferLine) out.avoidLines.add(preferLine);
  }
  if (turn.trainMoving) {
    out.trainMoving = true;
    out.tags.push("Train moving");
    out.notes.push(preferLine ? `Good. Staying on the ${graph.lineName(preferLine)} line is back in the options.` : "Good. Here are the options again.");
  }

  for (const raw of turn.closedLines) {
    const line = matcher.line(raw);
    if (line) out.avoidLines.add(line);
    else out.problems.push(`I couldn’t find a “${raw}” line on the saved Tube map.`);
  }
  for (const line of [...out.avoidLines].sort()) {
    out.tags.push(`No ${graph.lineName(line)} line`);
    out.notes.push(`Avoiding the ${graph.lineName(line)} line.`);
  }

  for (const section of turn.closedSections) {
    const a = matcher.match(section.from, preferLine), b = matcher.match(section.to, preferLine);
    if (a.kind !== "station" || b.kind !== "station") {
      out.problems.push(`I couldn’t place “${section.from}” and “${section.to}” on the saved Tube map.`);
      continue;
    }
    const named = section.line && matcher.line(section.line);
    const lines = named ? [named] : (graph.stations.get(a.id)?.lineIds ?? []).filter(l => graph.stations.get(b.id)?.lineIds.includes(l));
    const keys = new Set(lines.flatMap(l => [...graph.segmentKeys(l, a.id, b.id)]));
    if (!keys.size) {
      out.problems.push(`${name(a.id)} and ${name(b.id)} aren’t on the same line in the saved map, so I can’t tell which section is closed.`);
      continue;
    }
    keys.forEach(k => out.avoidSegments.add(k));
    out.notes.push(`Avoiding ${lines.length === 1 ? `the ${graph.lineName(lines[0])} line` : "trains"} between ${name(a.id)} and ${name(b.id)}.`);
    out.tags.push(`No service ${name(a.id)}–${name(b.id)}`);
  }

  for (const raw of turn.closedStations) {
    const match = matcher.match(raw, preferLine);
    if (match.kind === "station") {
      if (match.id === state.origin || match.id === (out.destination ?? state.destination)) continue;
      out.avoidStations.add(match.id);
      out.tags.push(`Avoid ${name(match.id)}`);
      out.notes.push(`Not changing or getting off at ${name(match.id)}.`);
    } else if (match.kind === "ambiguous") {
      out.problems.push(`There’s more than one ${titleCase(raw)}, so I haven’t avoided either. Say which line it’s on.`);
    } else out.problems.push(`I couldn’t find “${raw}” on the saved Tube map.`);
  }

  const leg = state.currentFirstLeg;
  if (turn.currentRouteBlocked && leg?.lineId && leg.stops.length >= 2) {
    leg.stops.slice(0, -1).forEach((x, i) => out.avoidSegments.add(`${segmentOf(leg.lineId, x, leg.stops[i + 1])}`));
    out.firstHop = segmentOf(leg.lineId, leg.stops[0], leg.stops[1]);
    out.tags.push("Not that route");
    out.notes.push(`OK, avoiding the ${graph.lineName(leg.lineId)} line between ${name(leg.stops[0])} and ${name(leg.stops.at(-1))}.`);
  }

  if (turn.stepFree === true) {
    out.stepFree = true; out.tags.push("Step-free");
    out.notes.push("Showing routes that only change at stations TfL lists with lift access. Lift outages aren’t known offline.");
  }
  if (turn.walking != null) {
    out.walking = turn.walking; out.tags.push(turn.walking ? "Walking OK" : "No walking");
    out.notes.push(turn.walking ? "Walking is included." : "OK, no walking routes.");
  }
  if (turn.fewerChanges) {
    out.fewerChanges = true; out.tags.push("Fewer changes");
    out.notes.push("Putting the route with the fewest changes first.");
  }
  out.asksForUnavailableInfo = turn.asksForUnavailableInfo;
  return out;
}

const segmentOf = (line, a, b) => (a < b ? `${line}|${a}|${b}` : `${line}|${b}|${a}`);

export const changesTrip = p => !!(p.origin || p.destination || p.onLine || p.situation || p.trainMoving
  || p.avoidLines.size || p.avoidSegments.size || p.avoidStations.size || p.stepFree != null || p.walking != null || p.fewerChanges);
