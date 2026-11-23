// Run with: node --test apps/web/
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { buildGraph, displayName, routeOptions, segmentKey } from "./route-engine.js";

const snapshot = JSON.parse(readFileSync(new URL("../../shared/fixtures/london-underground-network-v1.json", import.meta.url)));
const graph = buildGraph(snapshot);
const id = name => graph.sorted.find(s => s.name === name)?.id ?? assert.fail(`no station ${name}`);
const names = leg => leg.stops.map(s => graph.stations.get(s).name);

test("Camden Town → Warren Street fastest stays on the Charing Cross branch", () => {
  const [fastest] = routeOptions(graph, { origin: id("Camden Town"), destination: id("Warren Street"), onLine: "northern" });
  assert.equal(fastest.legs.length, 1);
  assert.deepEqual(names(fastest.legs[0]), ["Camden Town", "Mornington Crescent", "Euston", "Warren Street"]);
});

test("avoiding the branch falls back to Euston and the Victoria line", () => {
  const request = { origin: id("Camden Town"), destination: id("Warren Street"), onLine: "northern", includeWalking: false };
  const first = routeOptions(graph, request)[0].legs[0];
  const avoidSegments = new Set(first.stops.slice(0, -1).map((a, i) => segmentKey("northern", a, first.stops[i + 1])));
  const plan = routeOptions(graph, { ...request, avoidSegments })[0];
  assert.deepEqual(plan.legs.map(l => l.lineId), ["northern", "victoria"]);
  assert.deepEqual(names(plan.legs[1]), ["Euston", "Warren Street"]);
});

test("crossing Northern branches needs a change of train", () => {
  const avoidLines = new Set([...graph.lineNames.keys()].filter(l => l !== "northern"));
  const plan = routeOptions(graph, { origin: id("Angel"), destination: id("Mornington Crescent"), avoidLines, includeWalking: false })[0];
  assert.ok(plan.legs.length >= 2);
});

test("Brixton gets an alternative and real towards labels", () => {
  const plans = routeOptions(graph, { origin: id("Brixton"), destination: id("Warren Street"), includeWalking: false });
  assert.ok(plans.length >= 2);
  assert.equal(plans[0].legs[0].towards, "Walthamstow Central");
});

test("nearest station uses the full map", () => {
  assert.equal(graph.nearest({ latitude: 51.4627, longitude: -0.1145 }, 2000).station.name, "Brixton");
  assert.equal(graph.nearest({ latitude: 52.2053, longitude: 0.1218 }, 2000), null);
});

test("display names are cleaned", () => {
  assert.equal(displayName("Paddington (H&C Line)-Underground"), "Paddington (H&C Line)");
});
