// Deterministic route search over the offline TfL snapshot.
// Mirrors apps/ios/PockerRouter/Routing/RouteEngine.swift; keep the two in step.

const RIDE_METRES_PER_MIN = 550;
// Typical running speed between stops per line, in metres per minute.
// Mirrors NetworkGraph.lineMetresPerMinute in the iOS app.
export const LINE_METRES_PER_MIN = {
  metropolitan: 750, jubilee: 620, victoria: 600, central: 600, piccadilly: 580,
  northern: 550, "waterloo-city": 550, district: 480, bakerloo: 480, circle: 420, "hammersmith-city": 420
};
const DWELL_MIN = 0.6;
const BOARD_MIN = 4;
const CHANGE_MIN = 5;
const MAX_WALK_MIN = 40;

export function distanceMetres(a, b) {
  const rad = d => (d * Math.PI) / 180;
  const dLat = rad(b.latitude - a.latitude), dLon = rad(b.longitude - a.longitude);
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(rad(a.latitude)) * Math.cos(rad(b.latitude)) * Math.sin(dLon / 2) ** 2;
  return 6371000 * 2 * Math.atan2(Math.sqrt(h), Math.sqrt(1 - h));
}

export const walkMinutes = metres => (metres * 1.3) / 80;

export function displayName(raw) {
  let name = raw.replace(/&amp;/g, "&");
  for (const suffix of [" Underground Station", "-Underground", " Underground"]) {
    if (name.endsWith(suffix)) name = name.slice(0, -suffix.length);
  }
  return name.trim();
}

export function buildGraph(snapshot) {
  const stations = new Map();
  for (const s of snapshot.stations) {
    if (s.latitude == null || s.longitude == null) continue;
    stations.set(s.id, {
      id: s.id, name: displayName(s.name), latitude: s.latitude, longitude: s.longitude,
      lineIds: s.lineIds, liftAccess: s.accessViaLift == null ? null : s.accessViaLift.toLowerCase() === "yes"
    });
  }
  const lineNames = new Map(snapshot.lines.map(l => [l.id, l.name]));
  const routes = snapshot.routes.filter(r => r.serviceType.toLowerCase() === "regular");
  const edgesFrom = new Map();
  const seen = new Set();
  const continuations = new Set();
  for (const route of routes) {
    const ids = route.stationIds.filter(id => stations.has(id));
    for (let i = 0; i + 1 < ids.length; i++) {
      const key = `${route.lineId}|${ids[i]}|${ids[i + 1]}`;
      if (!seen.has(key)) {
        seen.add(key);
        const from = stations.get(ids[i]), to = stations.get(ids[i + 1]);
        const edge = { from: ids[i], to: ids[i + 1], lineId: route.lineId, minutes: DWELL_MIN + distanceMetres(from, to) / (LINE_METRES_PER_MIN[route.lineId] ?? RIDE_METRES_PER_MIN) };
        if (!edgesFrom.has(edge.from)) edgesFrom.set(edge.from, []);
        edgesFrom.get(edge.from).push(edge);
      }
      if (i + 2 < ids.length) continuations.add(`${route.lineId}|${ids[i]}|${ids[i + 1]}|${ids[i + 2]}`);
    }
  }
  const linked = new Map();
  for (const group of snapshot.interchanges) {
    if (group.type !== "linked-stations") continue;
    for (const id of group.stationIds) linked.set(id, [...(linked.get(id) || []), ...group.stationIds.filter(o => o !== id)]);
  }
  const sorted = [...stations.values()].sort((a, b) => a.name.localeCompare(b.name, "en-GB"));
  return {
    version: snapshot.version, generatedAt: snapshot.generatedAt, stations, sorted, lineNames, edgesFrom, linked, routes,
    lineName: id => lineNames.get(id) || id,
    continues: (line, a, b, c) => continuations.has(`${line}|${a}|${b}|${c}`),
    terminus(line, stops) {
      for (const route of routes) {
        if (route.lineId !== line) continue;
        const start = route.stationIds.indexOf(stops[0]);
        if (start < 0) continue;
        if (stops.every((id, i) => route.stationIds[start + i] === id)) return stations.get(route.stationIds.at(-1))?.name ?? null;
      }
      return null;
    },
    nearest(point, withinMetres) {
      let best = null, bestDistance = Infinity;
      for (const station of stations.values()) {
        const d = distanceMetres(point, station);
        if (d < bestDistance) { best = station; bestDistance = d; }
      }
      return best && bestDistance <= withinMetres ? { station: best, distance: bestDistance } : null;
    },
    segmentKeys(line, a, b) {
      const keys = new Set();
      for (const route of routes) {
        if (route.lineId !== line) continue;
        const i = route.stationIds.indexOf(a), j = route.stationIds.indexOf(b);
        if (i < 0 || j < 0 || i === j) continue;
        const slice = route.stationIds.slice(Math.min(i, j), Math.max(i, j) + 1);
        slice.slice(0, -1).forEach((x, k) => keys.add(segmentKey(line, x, slice[k + 1])));
      }
      return keys;
    },
    lineOrder(line, around) {
      const candidates = routes.filter(r => r.lineId === line && r.stationIds.includes(around));
      const longest = candidates.sort((a, b) => b.stationIds.length - a.stationIds.length)[0];
      return longest ? longest.stationIds.map(id => stations.get(id)).filter(Boolean) : [];
    }
  };
}

export const segmentKey = (line, a, b) => (a < b ? `${line}|${a}|${b}` : `${line}|${b}|${a}`);

// request: { origin, destination, onLine, trainStuck, avoidLines:Set, avoidSegments:Set, avoidStations:Set, stepFreeOnly, includeWalking }
export function routeOptions(graph, request) {
  const origin = graph.stations.get(request.origin), destination = graph.stations.get(request.destination);
  if (!origin || !destination || origin.id === destination.id) return [];
  const req = { avoidLines: new Set(), avoidSegments: new Set(), avoidStations: new Set(), includeWalking: true, ...request };
  const plans = [];
  const add = plan => { if (plan && !plans.some(p => p.id === plan.id)) plans.push(plan); };
  add(search(graph, req, CHANGE_MIN));
  add(search(graph, req, CHANGE_MIN + 25));
  if (plans.length === 1) {
    const best = plans[0];
    const alternatives = [];
    best.legs.filter(l => l.lineId).forEach((leg, index) => {
      const pairs = leg.stops.slice(0, -1).map((a, i) => [a, leg.stops[i + 1]]).slice(index === 0 ? 1 : 0);
      if (!pairs.length) return;
      const avoid = new Set(req.avoidSegments);
      for (const [a, b] of pairs) avoid.add(segmentKey(leg.lineId, a, b));
      const other = search(graph, { ...req, avoidSegments: avoid }, CHANGE_MIN);
      if (other && other.id !== best.id) alternatives.push(other);
    });
    alternatives.sort((a, b) => a.minutes - b.minutes);
    add(alternatives[0]);
  }
  if (req.includeWalking) {
    const metres = distanceMetres(origin, destination);
    const minutes = walkMinutes(metres);
    if (minutes <= MAX_WALK_MIN) {
      add(makePlan([{ lineId: null, metres: Math.round(metres * 1.3), stops: [origin.id, destination.id], minutes }], minutes));
    }
  }
  plans.sort((a, b) => a.minutes - b.minutes);
  if (plans[0]) plans[0].badge = "Fastest";
  const transit = plans.filter(p => !p.walkOnly).sort((a, b) => a.changes - b.changes || a.minutes - b.minutes);
  if (transit[0] && transit[0] !== plans[0] && transit[0].changes < (plans[0]?.changes ?? 0)) transit[0].badge = "Fewest changes";
  return plans;
}

function makePlan(legs, total) {
  const rides = legs.filter(l => l.lineId);
  return {
    id: legs.map(l => `${l.lineId || "walk"}:${l.stops.join(",")}`).join("/"),
    legs, minutes: Math.max(Math.round(total), 1), changes: Math.max(rides.length - 1, 0), walkOnly: rides.length === 0, badge: null
  };
}

function search(graph, req, changeWeight) {
  const allowed = e => !req.avoidLines.has(e.lineId) && !req.avoidSegments.has(segmentKey(e.lineId, e.from, e.to));
  // Trains may pass through a closed station, but nobody changes, walks or gets off there.
  const canChange = id => (!req.avoidStations.has(id) || id === req.origin) && (!req.stepFreeOnly || graph.stations.get(id)?.liftAccess === true);
  const key = s => `${s.station}|${s.line ?? ""}|${s.previous ?? ""}|${s.start ? 1 : 0}`;
  const start = { station: req.origin, line: null, previous: null, start: true };
  const cost = new Map([[key(start), 0]]);
  const back = new Map();
  const visited = new Set();
  const queue = [[0, start]];

  const relax = (from, fromCost, next, step, extra) => {
    const k = key(next), total = fromCost + extra;
    if (total < (cost.get(k) ?? Infinity)) {
      cost.set(k, total); back.set(k, [from, step]);
      // Small graph: a sorted insert is plenty.
      let i = queue.findIndex(([c]) => c > total);
      queue.splice(i < 0 ? queue.length : i, 0, [total, next]);
    }
  };

  while (queue.length) {
    const [current, state] = queue.shift();
    const k = key(state);
    if (visited.has(k)) continue;
    visited.add(k);
    if (state.station === req.destination) return buildPlan(graph, req, state, back, key);
    const edges = graph.edgesFrom.get(state.station) || [];
    if (state.line) {
      for (const e of edges) {
        if (e.lineId !== state.line || !allowed(e) || e.to === state.previous) continue;
        const through = state.previous ? graph.continues(state.line, state.previous, state.station, e.to) : true;
        if (!through && !canChange(state.station)) continue;
        relax(state, current, { station: e.to, line: state.line, previous: state.station, start: false },
          { type: "ride", line: e.lineId, from: e.from, to: e.to, minutes: e.minutes, sameLineChange: !through }, e.minutes + (through ? 0 : changeWeight));
      }
      if (canChange(state.station)) relax(state, current, { station: state.station, line: null, previous: null, start: false }, { type: "alight" }, 0);
    } else {
      for (const e of edges) {
        if (!allowed(e)) continue;
        const wait = state.start ? (e.lineId === req.onLine && !req.trainStuck ? 0 : BOARD_MIN) : changeWeight;
        relax(state, current, { station: e.to, line: e.lineId, previous: state.station, start: false },
          { type: "ride", line: e.lineId, from: e.from, to: e.to, minutes: e.minutes, sameLineChange: false }, e.minutes + wait);
      }
      for (const other of graph.linked.get(state.station) || []) {
        if (req.avoidStations.has(other)) continue;
        const a = graph.stations.get(state.station), b = graph.stations.get(other);
        if (!a || !b) continue;
        const metres = distanceMetres(a, b), minutes = walkMinutes(metres) + 2;
        relax(state, current, { station: other, line: null, previous: null, start: false }, { type: "walk", from: a.id, to: b.id, metres, minutes }, minutes);
      }
    }
  }
  return null;
}

function buildPlan(graph, req, end, back, key) {
  const steps = [];
  for (let k = key(end); back.has(k);) {
    const [previous, step] = back.get(k);
    steps.unshift(step);
    k = key(previous);
  }
  const legs = [];
  let line = null, stops = [], minutes = 0, total = 0;
  const close = () => {
    if (line && stops.length >= 2) legs.push({ lineId: line, towards: graph.terminus(line, stops), stops, minutes });
    line = null; stops = []; minutes = 0;
  };
  for (const step of steps) {
    if (step.type === "ride") {
      if (line !== step.line || step.sameLineChange) {
        close();
        if (legs.length) total += CHANGE_MIN;
        line = step.line; stops = [step.from];
      }
      stops.push(step.to); minutes += step.minutes; total += step.minutes;
    } else if (step.type === "alight") {
      close();
    } else {
      close();
      legs.push({ lineId: null, metres: Math.round(step.metres * 1.3), stops: [step.from, step.to], minutes: step.minutes });
      total += step.minutes;
    }
  }
  close();
  if (legs[0]?.lineId && (legs[0].lineId !== req.onLine || req.trainStuck)) total += BOARD_MIN;
  return makePlan(legs, total);
}
