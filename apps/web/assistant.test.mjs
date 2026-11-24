// Run with: node --test apps/web/*.test.mjs
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { createMatcher, interpret, keywordParse, planTurn, turnFromModel } from "./assistant.js";
import { buildGraph, routeOptions } from "./route-engine.js";

const read = path => JSON.parse(readFileSync(new URL(path, import.meta.url)));
const graph = buildGraph(read("../../shared/fixtures/london-underground-network-v1.json"));
const matcher = createMatcher(graph);
const evalCases = read("../../shared/fixtures/assistant-eval.json").cases;
const id = name => graph.sorted.find(s => s.name === name)?.id ?? assert.fail(`no station ${name}`);
const nameOf = raw => {
  if (!raw) return null;
  const m = matcher.match(raw);
  return m.kind === "station" ? graph.stations.get(m.id).name : `?${raw}`;
};

/** Same scoring as AssistantEvalTests.swift: listed fields must match, unlisted ones stay empty. */
function mismatches(turn, expect) {
  const problems = [];
  const station = raw => {
    if (!raw) return null;
    const m = matcher.match(raw, turn.line ? matcher.line(turn.line) : null);
    return m.kind === "station" ? graph.stations.get(m.id).name : `?${raw}`;
  };
  const check = (field, got, want) => { if (JSON.stringify(got) !== JSON.stringify(want)) problems.push(`${field}: got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`); };
  const sorted = list => [...new Set(list)].sort();
  check("currentStation", station(turn.currentStation), expect.currentStation ?? null);
  check("destination", station(turn.destination), expect.destination ?? null);
  if (expect.unassignedStation) check("unassignedStation", station(turn.unassignedStation), expect.unassignedStation);
  check("line", turn.line ? matcher.line(turn.line) : null, expect.line ?? null);
  check("situation", turn.situation, expect.situation ?? null);
  check("closedLines", sorted(turn.closedLines.map(matcher.line).filter(Boolean)), sorted(expect.closedLines ?? []));
  check("closedStations", sorted(turn.closedStations.map(station).filter(Boolean)), sorted(expect.closedStations ?? []));
  check("closedSection", turn.closedSections[0] ? [station(turn.closedSections[0].from), station(turn.closedSections[0].to)] : null, expect.closedSection ?? null);
  check("trainMoving", turn.trainMoving, expect.trainMoving ?? false);
  check("currentRouteBlocked", turn.currentRouteBlocked, expect.currentRouteBlocked ?? false);
  check("stepFree", turn.stepFree ?? false, expect.stepFree ?? false);
  check("walking", turn.walking, expect.walking ?? null);
  check("fewerChanges", turn.fewerChanges, expect.fewerChanges ?? false);
  check("asksForUnavailableInfo", turn.asksForUnavailableInfo, expect.asksForUnavailableInfo ?? false);
  return problems;
}

test("keyword rules score on the labelled messages", () => {
  const failures = evalCases.map(c => [c.text, mismatches(keywordParse(c.text, matcher), c.expect)]).filter(([, p]) => p.length);
  const passed = evalCases.length - failures.length;
  console.log(`Keyword rules: ${passed}/${evalCases.length}\n${failures.map(([t, p]) => `“${t}”: ${p.join("; ")}`).join("\n")}`);
  assert.ok(passed >= 29, `${passed}/${evalCases.length}`);
});

test("station names, short forms and typos resolve", () => {
  assert.equal(nameOf("kx"), "King's Cross St. Pancras");
  assert.equal(nameOf("warren st"), "Warren Street");
  assert.equal(nameOf("picadilly circus"), "Piccadilly Circus");
  assert.equal(nameOf("st pauls"), "St. Paul's");
  assert.equal(nameOf("Camden"), "Camden Town");
  assert.equal(matcher.match("Edgware Road").kind, "ambiguous");
  assert.equal(matcher.match("Hogwarts").kind, "unknown");
  assert.equal(matcher.line("the Northern line"), "northern");
});

test("one sentence gets straight to routes", () => {
  const turn = keywordParse("Held at Camden on the Northern, need Warren St", matcher);
  const planned = planTurn(turn, {}, matcher);
  assert.equal(planned.origin, id("Camden Town"));
  assert.equal(planned.destination, id("Warren Street"));
  assert.equal(planned.onLine, "northern");
  const plans = routeOptions(graph, { origin: planned.origin, destination: planned.destination, onLine: planned.onLine, trainStuck: true });
  assert.ok(plans.length >= 2);
});

test("an ambiguous station becomes a question with choices", () => {
  const planned = planTurn(keywordParse("I'm at Edgware Road", matcher), {}, matcher);
  assert.equal(planned.question.field, "origin");
  assert.equal(planned.question.choices.length, 2);
});

test("a closed section avoids just that stretch", () => {
  const planned = planTurn(keywordParse("no trains between Camden and Euston", matcher), { onLine: "northern" }, matcher);
  assert.ok(planned.avoidSegments.size >= 1);
  const plans = routeOptions(graph, { origin: id("Camden Town"), destination: id("Warren Street"), avoidSegments: planned.avoidSegments, includeWalking: false });
  for (const plan of plans) for (const leg of plan.legs) assert.ok(!(leg.lineId === "northern" && leg.stops.includes(id("Mornington Crescent"))));
});

test("a closed station is never a change or a stop", () => {
  const planned = planTurn(keywordParse("Bank is shut", matcher), { origin: id("Liverpool Street"), destination: id("London Bridge") }, matcher);
  assert.ok(planned.avoidStations.has(id("Bank")));
  const plans = routeOptions(graph, { origin: id("Liverpool Street"), destination: id("London Bridge"), avoidStations: planned.avoidStations, includeWalking: false });
  assert.ok(plans.length);
  for (const plan of plans) plan.legs.slice(1).forEach(leg => assert.notEqual(leg.stops[0], id("Bank")));
});

test("a model can't slip in a station the passenger never said", async () => {
  const readModel = async () => ({ turn: turnFromModel({ destination: "Brixton", situation: "held", stepFree: false }), by: "cloud" });
  const { turn, by } = await interpret("my train is held", {}, matcher, readModel);
  assert.equal(by, "cloud");
  assert.equal(turn.destination, null);
  assert.equal(turn.situation, "held");
});

test("a failed or slow model falls back to keyword rules", async () => {
  const failing = async () => { throw new Error("offline"); };
  assert.equal((await interpret("held at bank", {}, matcher, failing)).by, "keywords");
  const slow = () => new Promise(() => {});
  assert.equal((await interpret("held at bank", {}, matcher, slow, 20)).by, "keywords");
});

test("a model's invented closures are dropped", async () => {
  const cases = [
    ["Held at Camden on the Northern, need Warren St", { currentStation: "Camden", destination: "Warren St", line: "Northern", closedLines: ["Northern"], closedStations: ["Warren St"] }],
    ["no trains between Camden and Euston", { closedFrom: "Camden", closedTo: "Euston", closedStations: ["Euston", "Camden Town"] }],
    ["Northern line suspended between Kennington and Stockwell", { closedFrom: "Kennington", closedTo: "Stockwell", closedLines: ["Northern"] }],
    ["I have a buggy so lifts only", { stepFree: true, fewerChanges: true }]
  ];
  for (const [text, reply] of cases) {
    const { turn } = await interpret(text, {}, matcher, async () => ({ turn: turnFromModel(reply), by: "onDevice" }));
    const exp = evalCases.find(c => c.text === text).expect;
    assert.deepEqual(mismatches(turn, exp), [], text);
  }
});
