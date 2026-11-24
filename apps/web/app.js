import { changesTrip, createMatcher, interpret, planTurn, SITUATION_NAMES } from "./assistant.js";
import { isConfigured, modelReader, onDeviceStatus } from "./firebase-ai.js";
import { buildGraph, distanceMetres, routeOptions } from "./route-engine.js";

const DATA_URL = "/data/london-underground-network-v1.json";
const MAX_STATION_DISTANCE = 2000;
const MAX_FIX_AGE_MS = 12 * 3600 * 1000;
const SITUATIONS = [["Train held", "❚❚"], ["Terminating here", "⊟"], ["Line closed", "⊗"], ["Missed my stop", "⇥"]];
const LINE_COLOURS = {
  bakerloo: ["#b36305", "#fff"], central: ["#e32017", "#fff"], circle: ["#ffd300", "#000"], district: ["#00782a", "#fff"],
  "hammersmith-city": ["#f3a9bb", "#000"], jubilee: ["#a0a5a9", "#000"], metropolitan: ["#9b0056", "#fff"], northern: ["#000", "#fff"],
  piccadilly: ["#003688", "#fff"], victoria: ["#0098d4", "#fff"], "waterloo-city": ["#95cdba", "#000"]
};

const store = {
  get(key, fallback) { try { const v = localStorage.getItem(key); return v == null ? fallback : JSON.parse(v); } catch { return fallback; } },
  set(key, value) { try { localStorage.setItem(key, JSON.stringify(value)); } catch { /* private mode */ } }
};

const state = {
  graph: null, loadError: null,
  view: "route", screen: "capture",
  originId: null, originConfirmed: false, destinationId: null, onLine: null, situations: new Set(),
  thread: [], request: null, selected: null, step: 0, expanded: new Set(),
  picker: { origin: true, pending: null, browseAll: false },
  location: { fix: store.get("pocketroute.lastFix", null), status: "idle", suggestion: null },
  online: navigator.onLine,
  prefs: { stepFree: store.get("pocketroute.stepFree", false), walking: true, cloud: store.get("pocketroute.cloudAssist", false) },
  matcher: null, awaiting: null, thinking: false, constraints: null,
  ai: { onDevice: "unavailable", configured: false },
  recents: store.get("pocketroute.recents", []),
  permission: null, // geolocation permission: "granted" | "prompt" | "denied" | null (unknown)
  install: { prompt: null, dismissed: store.get("pocketroute.installDismissed", false) },
  updateReady: false,
  storage: { supported: !!navigator.storage?.persist, persisted: false }
};
if (state.location.fix && Date.now() - state.location.fix.time > MAX_FIX_AGE_MS) state.location.fix = null;

const app = document.querySelector("#app");
const dialog = document.querySelector("#station-dialog");
const offlineDialog = document.querySelector("#offline-dialog");
const menuDialog = document.querySelector("#menu-dialog");
const locationDialog = document.querySelector("#location-dialog");
const toasts = document.querySelector("#toasts");
// Tapping the dimmed area outside the side menu closes it.
menuDialog.addEventListener("click", event => { if (event.target === menuDialog && !drawer.dragged) closeMenu(); });
const pickerTitle = document.querySelector("#picker-title");
const searchInput = document.querySelector("#station-search");
const stationList = document.querySelector("#station-list");
const esc = value => String(value).replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
const nameOf = id => state.graph?.stations.get(id)?.name ?? "";
const savedDate = () => state.graph ? new Date(state.graph.generatedAt).toLocaleDateString("en-GB", { day: "numeric", month: "short" }) : "";

function lineTag(lineId, label) {
  const [bg, fg] = LINE_COLOURS[lineId] || ["var(--accent)", "#fff"];
  return `<span class="line-tag" style="background:${bg};color:${fg}">${esc(label)}</span>`;
}

// MARK: - Location

/** Match the last fix against the loaded map, so the suggestion always uses the full station list. */
function recomputeSuggestion() {
  const { fix } = state.location;
  if (!state.graph || !fix) { state.location.suggestion = null; return; }
  const match = state.graph.nearest(fix, MAX_STATION_DISTANCE);
  state.location.suggestion = match?.station.id ?? null;
  state.location.status = match ? "found" : "outside";
  if (match && !state.originConfirmed) {
    state.originId = match.station.id;
    if (state.destinationId === state.originId) state.destinationId = null;
  }
}

function locate() {
  if (!navigator.geolocation) { state.location.status = "unavailable"; return refresh(); }
  if (state.permission === "denied") { state.location.status = "denied"; return refresh(); }
  state.location.status = "locating";
  refresh();
  navigator.geolocation.getCurrentPosition(position => {
    const { latitude, longitude, accuracy } = position.coords;
    if (accuracy > 1000) { state.location.status = state.location.suggestion ? "found" : "rough"; return refresh(); }
    state.location.fix = { latitude, longitude, accuracy, time: Date.now() };
    store.set("pocketroute.lastFix", state.location.fix);
    recomputeSuggestion();
    refresh();
  }, error => {
    if (error.code === error.PERMISSION_DENIED) state.permission = "denied";
    state.location.status = error.code === error.PERMISSION_DENIED ? "denied" : (state.location.suggestion ? "found" : "failed");
    refresh();
  }, { enableHighAccuracy: true, timeout: 10000, maximumAge: 60000 });
}

function locationText() {
  const name = nameOf(state.location.suggestion);
  switch (state.location.status) {
    case "found": return name ? `Nearest station: ${name}` : "Choose your station";
    case "locating": return "Checking nearby stations…";
    case "denied": return "Location is blocked for this site";
    case "unavailable": return "Location isn’t available in this browser.";
    case "rough": return "Location is too rough to pick a station.";
    case "outside": return "You’re not near a station on this map.";
    case "failed": return "Couldn’t get a fix. GPS often drops underground.";
    default: return "Suggest my nearest station";
  }
}

// MARK: - Search and follow-ups

// The Ask AI tab: search with the form when it's complete and the thread is
// empty or about another trip; otherwise reopen the conversation.
function openAssistant() {
  const canSearch = state.originId && state.destinationId && state.originId !== state.destinationId;
  const sameTrip = state.request?.origin === state.originId && state.request?.destination === state.destinationId;
  if (canSearch && (!state.thread.length || (state.request && !sameTrip))) return startSearch();
  state.screen = "results";
  render();
}

const freshConstraints = () => ({ avoidLines: new Set(), avoidSegments: new Set(), avoidStations: new Set(), stepFree: state.prefs.stepFree, walking: state.prefs.walking, fewerChanges: false });

/** Routes for the trip as it stands: the form's stations and situations plus everything said in the conversation. */
function search() {
  if (!state.originId || !state.destinationId || state.originId === state.destinationId) { state.request = null; return []; }
  const c = state.constraints ?? (state.constraints = freshConstraints());
  const request = {
    origin: state.originId, destination: state.destinationId, onLine: state.onLine,
    trainStuck: state.situations.has("Train held") || state.situations.has("Terminating here"),
    avoidLines: new Set([...c.avoidLines, ...(state.situations.has("Line closed") && state.onLine ? [state.onLine] : [])]),
    avoidSegments: new Set(c.avoidSegments), avoidStations: new Set(c.avoidStations),
    stepFreeOnly: c.stepFree, includeWalking: c.walking
  };
  state.request = request;
  const plans = routeOptions(state.graph, request);
  if (c.fewerChanges) plans.sort((a, b) => (a.walkOnly - b.walkOnly) || a.changes - b.changes || a.minutes - b.minutes);
  return plans;
}

function startSearch() {
  if (!state.originId || !state.destinationId || state.originId === state.destinationId) return;
  state.constraints = freshConstraints();
  state.awaiting = null;
  const plans = search();
  const opener = state.onLine ? `I’m on the ${state.graph.lineName(state.onLine)} line at ${nameOf(state.originId)}.` : `I’m at ${nameOf(state.originId)}.`;
  const reported = SITUATIONS.map(([n]) => n).filter(n => state.situations.has(n));
  const user = [opener, reported.length ? `${reported.join(", ")}.` : "", `How do I get to ${nameOf(state.destinationId)}?`].filter(Boolean).join(" ");
  state.thread = [{ id: crypto.randomUUID(), user, reply: openingReply(plans), plans }];
  state.expanded.clear();
  state.selected = null;
  state.screen = "results";
  render();
}

function openingReply(plans) {
  const dest = nameOf(state.request.destination);
  if (!plans.length) return `I couldn’t find a route to ${dest} on the saved map with those conditions.`;
  return plans.length === 1 ? `Here’s the best way to ${dest} from here:` : `There are ${plans.length} ways to ${dest} from here:`;
}

const NO_LIVE_INFO = "I can’t see live service, delays or platforms offline. If you know a line or station is closed, tell me and I’ll route around it.";
const UNDERSTOOD_BY = { onDevice: "Understood in this browser", cloud: "Understood by Gemini", keywords: "Matched by keywords", tap: "Tapped" };

function conversationContext() {
  const plan = state.thread.at(-1)?.plans?.[0];
  return {
    origin: nameOf(state.originId) || null, destination: nameOf(state.destinationId) || null,
    line: state.onLine ? state.graph.lineName(state.onLine) : null,
    currentRoute: plan ? plan.legs.map(l => (l.lineId ? `${state.graph.lineName(l.lineId)} line ${nameOf(l.stops[0])} to ${nameOf(l.stops.at(-1))}` : `walk to ${nameOf(l.stops.at(-1))}`)).join(", then ") : null
  };
}

/**
 * A typed message or a quick reply, on the first screen or in the conversation.
 * Chips are read by keyword rules so a tap never waits for a model.
 */
async function sendMessage(text, { quick = false } = {}) {
  const trimmed = text.trim();
  if (!trimmed || state.thinking || !state.matcher) return;
  const entry = { id: crypto.randomUUID(), user: trimmed, reply: "", plans: [], pending: true, tags: [], by: null, question: null };
  if (!state.request && !state.thread.length) state.constraints = freshConstraints();
  state.thread.push(entry);
  state.selected = null; state.view = "route"; state.screen = "results"; state.thinking = true;
  render();

  const reader = quick ? null : await modelReader({ allowCloud: state.prefs.cloud }).catch(() => null);
  const { turn, by } = await interpret(trimmed, conversationContext(), state.matcher, reader);
  const latest = state.thread.slice(0, -1).at(-1)?.plans ?? [];
  const planned = planTurn(turn, {
    origin: state.originId, destination: state.destinationId, onLine: state.onLine, awaiting: state.awaiting,
    currentFirstLeg: latest[0]?.legs.find(l => l.lineId) ?? null
  }, state.matcher);
  applyPlanned(planned);
  respond(entry, planned, quick ? "tap" : by);
}

function applyPlanned(planned) {
  const c = state.constraints ?? (state.constraints = freshConstraints());
  if (planned.origin) {
    state.originId = planned.origin; state.originConfirmed = true;
    if (state.destinationId === planned.origin) state.destinationId = null;
    if (state.onLine && !state.graph.stations.get(planned.origin).lineIds.includes(state.onLine)) state.onLine = null;
  }
  if (planned.destination && planned.destination !== state.originId) state.destinationId = planned.destination;
  if (planned.onLine) state.onLine = planned.onLine;
  if (planned.situation) state.situations.add(SITUATION_NAMES[planned.situation]);
  if (planned.trainMoving) { state.situations.delete("Train held"); state.situations.delete("Terminating here"); }
  planned.avoidLines.forEach(l => c.avoidLines.add(l));
  planned.avoidSegments.forEach(k => c.avoidSegments.add(k));
  planned.avoidStations.forEach(id => c.avoidStations.add(id));
  if (planned.stepFree != null) c.stepFree = planned.stepFree;
  if (planned.walking != null) c.walking = planned.walking;
  if (planned.fewerChanges) c.fewerChanges = true;
  if (planned.origin && state.awaiting === "origin") state.awaiting = null;
  if (planned.destination && state.awaiting === "destination") state.awaiting = null;
}

function defaultChoices(field) {
  if (field === "origin") {
    const ids = state.location.suggestion ? [state.location.suggestion] : [];
    if (state.onLine && state.destinationId) ids.push(...state.graph.lineOrder(state.onLine, state.destinationId).map(s => s.id));
    return [...new Set(ids)].filter(id => id !== state.destinationId).slice(0, 4);
  }
  return [...new Set(state.recents.map(r => r.destination))].filter(id => id !== state.originId && state.graph.stations.has(id)).slice(0, 4);
}

function respond(entry, planned, by, answeredQuestion = false) {
  entry.pending = false;
  entry.tags = planned.tags;
  entry.by = by;
  const problems = planned.problems.join(" ");
  const join = parts => parts.filter(Boolean).join(" ");
  const previous = state.thread.slice(0, -1).at(-1)?.plans ?? [];
  const canSearch = state.originId && state.destinationId && state.originId !== state.destinationId;

  if (planned.question) {
    state.awaiting = planned.question.field;
    entry.reply = join([problems, planned.question.prompt]);
    entry.question = { field: planned.question.field, choices: planned.question.choices };
  } else if (!canSearch) {
    const field = state.originId ? "destination" : "origin";
    state.awaiting = field;
    entry.reply = join([problems, planned.notes.join(" "), field === "origin" ? "Which station are you at now?" : "Where are you trying to get to?"]);
    entry.question = { field, choices: defaultChoices(field) };
  } else if (changesTrip(planned) || !state.request || answeredQuestion) {
    let plans = search();
    // The closure also cut the only way out of this station: keep the first hop.
    if (!plans.length && planned.firstHop) { state.constraints.avoidSegments.delete(planned.firstHop); plans = search(); }
    entry.plans = plans;
    const notes = [...planned.notes, ...(planned.asksForUnavailableInfo ? [NO_LIVE_INFO] : [])].join(" ");
    const dest = nameOf(state.destinationId);
    const routes = plans.length ? (plans.length === 1 ? `Here’s the best way to ${dest}:` : `Here are ${plans.length} ways to ${dest}:`) : `I couldn’t find a route to ${dest} on the saved map with those conditions.`;
    entry.reply = join([problems, notes, routes]);
  } else if (planned.asksForUnavailableInfo) {
    entry.reply = `${NO_LIVE_INFO} Your routes haven’t changed.`; entry.plans = previous;
  } else if (problems) {
    entry.reply = `${problems} Your routes haven’t changed.`; entry.plans = previous;
  } else {
    entry.reply = "I didn’t catch a change to your trip, so your routes haven’t changed. Try a quick reply, or say something like “the Victoria line is closed” or “I’m at Euston now”.";
    entry.plans = previous;
  }
  state.thinking = false;
  render();
}

/** The passenger tapped one of the stations offered in a question. */
function chooseAnswer(id) {
  const field = state.awaiting;
  if (!field || state.thinking) return;
  const name = nameOf(id);
  const entry = { id: crypto.randomUUID(), user: name, reply: "", plans: [], pending: true, tags: [], by: null, question: null };
  state.thread.push(entry);
  if (field === "origin") { state.originId = id; state.originConfirmed = true; if (state.destinationId === id) state.destinationId = null; }
  else state.destinationId = id;
  state.awaiting = null;
  const planned = planTurn({ ...emptyPlannedTurn() }, {}, state.matcher);
  planned.tags = [field === "origin" ? `At ${name}` : `To ${name}`];
  respond(entry, planned, "tap", true);
}

const emptyPlannedTurn = () => ({ currentStation: null, destination: null, line: null, situation: null, trainMoving: false, closedLines: [], closedSections: [], closedStations: [], currentRouteBlocked: false, stepFree: null, walking: null, fewerChanges: false, asksForUnavailableInfo: false, unassignedStation: null });

// MARK: - Route text

function routeTitle(plan) {
  if (plan.walkOnly) return "Walk instead";
  const lines = [];
  for (const leg of plan.legs) if (leg.lineId && lines.at(-1) !== leg.lineId) lines.push(leg.lineId);
  const rides = plan.legs.filter(l => l.lineId).length;
  if (lines.length === 1) return `${state.graph.lineName(lines[0])} line${rides > 1 ? ", change trains" : ""}`;
  return lines.map(state.graph.lineName).join(" → ");
}

const distance = m => (m < 1000 ? `${Math.round(m / 10) * 10} m` : `${(m / 1000).toFixed(1)} km`);

function routeDetail(plan) {
  if (plan.walkOnly) return `${distance(plan.legs[0].metres)} · leave the station`;
  const rides = plan.legs.filter(l => l.lineId);
  const stops = rides.reduce((n, l) => n + l.stops.length - 1, 0);
  const stopText = stops === 1 ? "1 stop" : `${stops} stops`;
  return plan.changes ? `${stopText} · change at ${rides.slice(1).map(l => nameOf(l.stops[0])).join(", ")}` : `${stopText} · no changes`;
}

function instruction(leg, index) {
  if (!leg.lineId) return `Walk to ${nameOf(leg.stops.at(-1))}`;
  const line = state.graph.lineName(leg.lineId);
  const towards = leg.towards ? ` towards ${leg.towards}` : "";
  if (index === 0) return leg.lineId === state.request?.onLine && !state.request?.trainStuck ? `Stay on the ${line} line${towards}` : `Take the ${line} line${towards}`;
  return `At ${nameOf(leg.stops[0])}, change to the ${line} line${towards}`;
}

function legDetail(leg) {
  if (!leg.lineId) return `About ${distance(leg.metres)} · ${Math.max(Math.round(leg.minutes), 1)} min on foot`;
  const stops = leg.stops.length - 1;
  return `${stops === 1 ? "1 stop" : `${stops} stops`} · get off at ${nameOf(leg.stops.at(-1))}`;
}

// MARK: - Rendering

function refresh() { if (dialog.open) populateStations(); render(); }

function render() {
  // Every tab shows the tab bar; step-by-step guidance doesn't.
  const hideTabs = state.view === "route" && state.screen === "guidance";
  const activeTab = state.view === "route" && state.screen === "results" ? "ask" : state.view;
  document.querySelector(".tabs").hidden = hideTabs || !state.graph;
  document.querySelectorAll(".tab").forEach(b => { const on = b.dataset.tab === activeTab; b.classList.toggle("active", on); b.setAttribute("aria-current", on ? "page" : "false"); });
  document.body.classList.toggle("no-tabs", hideTabs || !state.graph);
  document.body.classList.toggle("has-composer", state.view === "route" && state.screen === "results");
  renderToasts();
  if (!state.graph) {
    app.innerHTML = `<section class="screen stack"><h1 class="hero">${state.loadError ? "Couldn’t load the Tube map" : "Loading the saved Tube map…"}</h1>${state.loadError ? `<p>${esc(state.loadError)}</p>` : ""}</section>`;
    return;
  }
  if (state.view === "saved") return renderSaved();
  if (state.view === "settings") return renderSettings();
  if (state.screen === "guidance" && state.selected) return renderGuidance();
  if (state.screen === "results") return renderResults();
  renderCapture();
}

const WIFI_ICON = `<svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M5 12.55a11 11 0 0 1 14 0"/><path d="M1.42 9a16 16 0 0 1 21.16 0"/><path d="M8.53 16.11a6 6 0 0 1 6.95 0"/><path d="M12 20h.01"/></svg>`;
const WIFI_OFF_ICON = `<svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="m2 2 20 20"/><path d="M8.5 16.5a5 5 0 0 1 7 0"/><path d="M2 8.82a15 15 0 0 1 4.17-2.65"/><path d="M10.66 5c4.01-.36 8.14.9 11.34 3.76"/><path d="M16.85 11.25a10 10 0 0 1 2.22 1.68"/><path d="M5 13a10 10 0 0 1 5.24-2.76"/><path d="M12 20h.01"/></svg>`;

const SEND_ICON = `<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M12 19V5"/><path d="m5 12 7-7 7 7"/></svg>`;
const CLOSE_ICON = `<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><path d="M18 6 6 18"/><path d="m6 6 12 12"/></svg>`;
const SHARE_ICON = `<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M12 3v12"/><path d="m8 7 4-4 4 4"/><path d="M6 11v9h12v-9"/></svg>`;
const PIN_ICON = `<svg width="32" height="32" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M12 21s-7-6.2-7-11.5a7 7 0 0 1 14 0C19 14.8 12 21 12 21Z"/><circle cx="12" cy="9.5" r="2.5"/></svg>`;
const LOCATION_OFF_ICON = `<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M12 21s-7-6.2-7-11.5a7 7 0 0 1 11.9-5"/><path d="M19 9.5c0 1.6-.6 3.3-1.6 4.9"/><path d="m3 3 18 18"/></svg>`;
const LOCK_ICON = `<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M7 11V8a5 5 0 0 1 10 0v3"/><rect x="5" y="11" width="14" height="10" rx="2"/></svg>`;
const TOGGLE_ICON = `<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="3" y="7" width="18" height="10" rx="5"/><circle cx="16" cy="12" r="2"/></svg>`;
const MENU_ICON = `<svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><path d="M4 6h16"/><path d="M4 12h16"/><path d="M4 18h16"/></svg>`;
const SETTINGS_ICON = `<svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><path d="M4 6h10"/><path d="M18 6h2"/><circle cx="16" cy="6" r="2"/><path d="M4 12h2"/><path d="M10 12h10"/><circle cx="8" cy="12" r="2"/><path d="M4 18h10"/><path d="M18 18h2"/><circle cx="16" cy="18" r="2"/></svg>`;
// Header shortcut to the Settings tab (used on Ask AI).
const settingsButton = () => `<button class="menu-button" data-tab="settings" aria-label="Settings">${SETTINGS_ICON}</button>`;
const menuButton = () => `<button class="menu-button" data-action="open-menu" aria-label="Open menu" aria-haspopup="dialog">${MENU_ICON}</button>`;

// Mobile top nav header: centered title, back or menu button, optional trailing control.
function topNav(title, { back = false, menu = false, trailing = "" } = {}) {
  const leading = back ? `<button aria-label="Back" data-action="back">‹</button>` : menu ? menuButton() : `<span class="nav-slot"></span>`;
  return `<header class="screen-header top-nav">${leading}<div><strong>${esc(title)}</strong></div>${trailing || `<span class="nav-slot"></span>`}</header>`;
}

function connectivityButton() {
  return `<button class="connectivity-button ${state.online ? "online" : ""}" data-action="offline-info" aria-haspopup="dialog" aria-label="${state.online ? "Online. Show details" : "You’re offline. Show details"}">${state.online ? WIFI_ICON : WIFI_OFF_ICON}</button>`;
}

function renderCapture() {
  const lines = state.graph.stations.get(state.originId)?.lineIds ?? [];
  const canSearch = state.originId && state.destinationId && state.originId !== state.destinationId;
  const originHint = !state.originId ? (state.location.status === "denied" ? "" : locationText()) : (!state.originConfirmed && state.location.suggestion === state.originId ? "Nearest station to your location · tap to change" : "");
  app.innerHTML = `<section class="screen stack has-top-nav">
    ${topNav("Re-route", { menu: true, trailing: connectivityButton() })}
    <h1 class="hero">Train stopped?<br>Let’s find another way.</h1>
    <div class="card">
      <button class="station-row" data-action="origin"><span class="row-icon">◎</span><span><span class="label">I’m at</span><br><strong>${esc(nameOf(state.originId) || "Choose your station")}</strong>${originHint ? `<br><small class="label">${esc(originHint)}</small>` : ""}</span><span class="chevron">›</span></button><div class="divider"></div>
      <button class="station-row" data-action="destination"><span class="row-icon">⚑</span><span><span class="label">Going to</span><br><strong>${esc(nameOf(state.destinationId) || "Choose where you’re going")}</strong></span><span class="chevron">›</span></button><div class="divider"></div>
      <label class="station-row"><span class="row-icon">▤</span><span><span class="label">I was on</span><br>
        <select data-action="on-line" ${lines.length ? "" : "disabled"} aria-label="Line you were on">
          <option value="">${lines.length ? "Not on a train" : "Choose your station first"}</option>
          ${lines.map(l => `<option value="${esc(l)}" ${l === state.onLine ? "selected" : ""}>${esc(state.graph.lineName(l))} line</option>`).join("")}
        </select></span></label>
    </div>
    ${state.location.status === "denied" ? `<button class="location-warning" data-action="location-blocked">${LOCATION_OFF_ICON}<span>Location is blocked for this site</span></button>` : ""}
    <h2 class="section-title">What happened?</h2>
    <div class="situations">${SITUATIONS.map(([name, glyph]) => `<button class="situation ${state.situations.has(name) ? "selected" : ""}" data-action="situation" data-value="${esc(name)}" aria-pressed="${state.situations.has(name)}"><span class="glyph">${state.situations.has(name) ? "✓" : glyph}</span><span>${name}</span></button>`).join("")}</div>
    ${canSearch ? `<button class="primary show-routes" data-action="find">Show routes</button>` : ""}
    <form class="compose-row describe-row" id="describe-form"><input name="followup" placeholder="Or describe what happened" aria-label="Describe what happened" autocomplete="off" enterkeyhint="send"/><button class="send" aria-label="Send" disabled>${SEND_ICON}</button></form>
  </section>`;
}

function routeCard(plan) {
  const tags = plan.walkOnly ? lineTag(null, "Walk") : plan.legs.filter(l => l.lineId).map(l => lineTag(l.lineId, state.graph.lineName(l.lineId))).join("");
  return `<button class="route-card ${plan.badge === "Fastest" ? "recommended" : ""}" data-action="choose-route" data-value="${esc(plan.id)}"><span class="route-top"><span class="route-copy"><span class="route-name">${esc(routeTitle(plan))}</span><span class="line-tags">${tags}${plan.badge ? `<span class="badge">${plan.badge}</span>` : ""}</span></span><span class="eta">${plan.minutes}<small>min</small></span><span class="chevron">›</span></span><span class="route-detail">${esc(routeDetail(plan))}</span></button>`;
}

function understoodRow(entry) {
  if (!entry.by) return "";
  const tags = entry.tags.map(t => `<span class="understood-tag">${esc(t)}</span>`).join("");
  const by = entry.tags.length ? UNDERSTOOD_BY[entry.by] : `${UNDERSTOOD_BY[entry.by]} · nothing to change`;
  return `<div class="understood">${tags ? `<div class="understood-tags">${tags}</div>` : ""}<small>${entry.by === "cloud" || entry.by === "onDevice" ? "✦ " : ""}${esc(by)}</small></div>`;
}

function choiceButtons(entry, latest) {
  if (!entry.question || !latest) return "";
  const choices = entry.question.choices.map(id => `<button class="chip choice" data-action="answer" data-value="${esc(id)}">${esc(nameOf(id))}${state.graph.stations.get(id)?.lineIds.length && entry.question.choices.filter(c => nameOf(c) === nameOf(id)).length > 1 ? ` · ${esc(state.graph.stations.get(id).lineIds.map(state.graph.lineName).join(", "))}` : ""}</button>`).join("");
  return `<div class="choices">${choices}<button class="chip choice" data-action="answer-other">Another station</button></div>`;
}

function renderResults() {
  if (!state.thread.length) {
    app.innerHTML = `<section class="screen stack results-screen">
      ${topNav("Ask AI", { menu: true, trailing: settingsButton() })}
      <div class="thread"><div class="assistant-message"><span class="assistant-mark">✦</span><div class="bubble">Tell me where you are, where you’re going and what happened, or choose stations on Re-route.</div></div>
      <button class="primary" data-action="back">Choose stations</button></div></section>
      <div class="composer"><form class="compose-row" id="follow-form"><input name="followup" placeholder="Held at Camden, need Warren St" aria-label="Describe what happened" autocomplete="off"/><button class="send" aria-label="Send" disabled>${SEND_ICON}</button></form></div>`;
    return;
  }
  const entries = state.thread.map((entry, i) => {
    const latest = i === state.thread.length - 1;
    const cards = latest || state.expanded.has(entry.id)
      ? entry.plans.map(routeCard).join("")
      : entry.plans.length ? `<button class="browse-stations" data-action="expand" data-value="${entry.id}">${entry.plans.length} earlier option${entry.plans.length === 1 ? "" : "s"} · Show</button>` : "";
    const reply = entry.pending ? `<div class="bubble thinking" role="status">Reading that against the saved map…</div>` : `<div class="bubble">${esc(entry.reply)}</div>`;
    return `<div class="user-message"><div class="bubble user">${esc(entry.user)}</div>${understoodRow(entry)}</div>
      <div class="assistant-message"><span class="assistant-mark">✦</span>${reply}</div>${choiceButtons(entry, latest)}${cards}`;
  }).join("");
  const title = state.request ? `${nameOf(state.request.origin)} → ${nameOf(state.request.destination)}` : "Ask AI";
  app.innerHTML = `<section class="screen stack results-screen">
    ${topNav(title, { menu: true, trailing: settingsButton() })}
    <div class="thread">${entries}</div></section>
    <div class="composer">${state.request ? `<div class="chips">${["Train is moving again", "Branch isn’t running", "Step-free only", "I’d rather walk"].map(t => `<button class="chip" data-action="follow" data-value="${esc(t)}">${esc(t)}</button>`).join("")}</div>` : ""}
    <form class="compose-row" id="follow-form"><input name="followup" placeholder="Type what’s changed" aria-label="Type what’s changed" autocomplete="off" ${state.thinking ? "disabled" : ""}/><button class="send" aria-label="Send" disabled>${SEND_ICON}</button></form></div>`;
  app.querySelector(".thread")?.lastElementChild?.scrollIntoView?.({ block: "nearest" });
}

function renderGuidance() {
  const plan = state.selected;
  const index = Math.min(state.step, plan.legs.length - 1);
  const leg = plan.legs[index];
  const isLast = index === plan.legs.length - 1;
  const elapsed = plan.legs.slice(0, index).reduce((n, l) => n + l.minutes, 0);
  const next = plan.legs[index + 1];
  const calls = leg.lineId && leg.stops.length > 2 ? `<p>Calls at ${esc(leg.stops.slice(1, -1).map(nameOf).join(", "))}</p>` : "";
  app.innerHTML = `<section class="screen stack guidance-screen"><header class="guidance-header"><button data-action="back">Close</button><strong>To ${esc(nameOf(plan.legs.at(-1).stops.at(-1)))}</strong><button data-action="ask">Ask</button></header><div class="guidance-body">
    <div class="step-count"><span>Step ${index + 1} of ${plan.legs.length}</span><small>About ${Math.max(plan.minutes - Math.round(elapsed), 1)} min to go</small></div>
    <div class="progress-track">${plan.legs.map((_, i) => `<i style="flex:1;opacity:${i <= index ? 1 : 0.25}"></i>`).join("")}</div>
    <article class="step-card"><span class="step-symbol">${leg.lineId ? (index === 0 ? "▤" : "⇄") : "⇢"}</span><h1 class="instruction">${esc(instruction(leg, index))}</h1><p>${esc(legDetail(leg))}</p>${calls}
      ${next ? `<div class="next-line">${lineTag(next.lineId, next.lineId ? state.graph.lineName(next.lineId) : "Walk")}<div><strong>Next: ${esc(instruction(next, index + 1))}</strong><small>${esc(legDetail(next))}</small></div></div>` : ""}</article>
    <div class="guidance-actions"><button class="primary" data-action="next">${isLast ? "Arrived · Finish" : leg.lineId ? `I’m off at ${esc(nameOf(leg.stops.at(-1)))}` : "I’m there"}</button><button class="secondary-button" data-action="reroute">⟳ &nbsp; Something’s wrong — find another way</button></div>
  </div></section>`;
}

function renderSaved() {
  const rows = state.recents.filter(r => state.graph.stations.has(r.origin) && state.graph.stations.has(r.destination)).map((r, i) =>
    `<button class="recent-row" data-action="recent" data-value="${i}"><span class="recent-icon">◷</span><span><strong>${esc(nameOf(r.origin))} → ${esc(nameOf(r.destination))}</strong><small>${esc(new Date(r.time).toLocaleString("en-GB", { weekday: "short", hour: "2-digit", minute: "2-digit" }))} · ${esc(r.summary)}</small></span><span>›</span></button>`).join("");
  app.innerHTML = `<section class="screen stack saved-screen"><div class="saved-heading title-row">${menuButton()}<h1>History</h1></div>
    ${rows ? `<div class="card recent-list">${rows}</div>` : `<p class="history-empty">No trips yet</p>`}</section>`;
}

function settingGroup(title, rows) {
  return `<div class="settings-group"><h2>${title}</h2><div class="card">${rows.map(([icon, name, description, trailing]) => `<div class="setting"><span class="row-icon">${icon}</span><span class="setting-copy"><strong>${name}</strong><small>${description}</small></span>${trailing || ""}</div>`).join("")}</div></div>`;
}

const AI_STATUS = { available: "On this device", downloadable: "Not downloaded yet", downloading: "Downloading", unavailable: "Not in this browser" };

// Only real choices: which models read messages, step-free routing, plus the TfL data credit the licence asks for.
function renderSettings() {
  app.innerHTML = `<section class="screen settings-screen stack"><div class="title-row">${menuButton()}<h1 class="settings-title">Settings</h1></div>
    <div class="settings-group"><h2>Map</h2><div class="card"><div class="setting"><span class="row-icon">◫</span><span class="setting-copy"><strong>City</strong><small>London · Tube · saved ${esc(savedDate())}</small></span></div>${state.storage.supported ? `<label class="setting"><span class="row-icon">▦</span><span class="setting-copy"><strong>Keep map stored</strong></span><input type="checkbox" data-action="persist" ${state.storage.persisted ? "checked disabled" : ""}/></label>` : ""}</div></div>
    ${settingGroup("Assistant", [["✦", "Chrome on-device model", AI_STATUS[state.ai.onDevice] ?? "Not in this browser"]])}
    ${state.ai.configured ? `<div class="settings-group assistant-cloud"><div class="card"><label class="setting"><span class="row-icon">☁</span><span class="setting-copy"><strong>Use Gemini when online</strong></span><input type="checkbox" data-action="cloud" ${state.prefs.cloud ? "checked" : ""}/></label></div></div>` : ""}
    <div class="settings-group"><h2>Routes</h2><div class="card"><label class="setting"><span class="row-icon">♿</span><span class="setting-copy"><strong>Step-free changes only</strong></span><input type="checkbox" data-action="stepfree" ${state.prefs.stepFree ? "checked" : ""}/></label></div></div>
    ${canInstall() ? settingGroup("App", [["⤓", "Install PocketRoute", "", `<button class="pill-button" data-action="install">Install</button>`]]) : ""}
    ${settingGroup("About", [["ⓘ", "Map data & licences", "TfL Open Data · Open Government Licence v3.0"]])}</section>`;
}

// MARK: - Station picker

function openPicker(isOrigin) {
  state.picker = { origin: isOrigin, pending: isOrigin ? state.originId : state.destinationId, browseAll: false };
  pickerTitle.textContent = isOrigin ? "Where are you?" : "Where are you going?";
  searchInput.value = "";
  populateStations();
  dialog.showModal();
  // Refresh the fix only when the site already has permission; asking happens in the location sheet.
  if (isOrigin && navigator.geolocation && state.permission === "granted") locate();
}

function curatedStations() {
  const graph = state.graph;
  const around = state.picker.pending ?? state.originId;
  if (state.picker.origin && state.onLine && around) {
    const order = graph.lineOrder(state.onLine, around);
    const i = order.findIndex(s => s.id === around);
    if (i >= 0) return { title: `On your line · ${graph.lineName(state.onLine)} line`, list: order.slice(Math.max(i - 4, 0), i + 5) };
  }
  if (state.location.fix) {
    const fix = state.location.fix;
    return { title: "Near your last known location", list: [...graph.stations.values()].sort((a, b) => distanceMetres(fix, a) - distanceMetres(fix, b)).slice(0, 8) };
  }
  return { title: "Stations", list: [] };
}

function subtitle(station) {
  if (station.id === state.location.suggestion) return "Nearest to your location";
  if (station.lineIds.length < 2) return "";
  const names = station.lineIds.filter(l => l !== state.onLine).map(state.graph.lineName);
  if (!state.onLine) return `${names.join(", ")} lines`;
  return names.length === 1 ? `Change for the ${names[0]} line` : `Change for ${names.join(", ")} lines`;
}

function populateStations() {
  const query = searchInput.value.trim().toLowerCase();
  const { pending, browseAll } = state.picker;
  const curated = curatedStations();
  let list, title;
  if (query) { list = state.graph.sorted.filter(s => s.name.toLowerCase().includes(query)); title = "Stations"; }
  else if (browseAll || !curated.list.length) { list = state.graph.sorted; title = "Stations"; }
  else {
    list = curated.list; title = curated.title;
    const chosen = state.graph.stations.get(pending);
    if (chosen && !list.includes(chosen)) list = [chosen, ...list];
  }
  stationList.innerHTML = `
    <p class="picker-section">${esc(title)}</p>
    <div class="picker-line-list">${list.map(s => `<button class="station-choice" data-station="${esc(s.id)}" aria-selected="${s.id === pending}"><span class="line-dot ${s.id === pending ? "current" : ""}"></span><span class="station-copy">${esc(s.name)}${subtitle(s) ? `<small>${esc(subtitle(s))}</small>` : ""}</span><span>${s.id === pending ? "✓" : ""}</span></button>`).join("")}</div>
    ${query || browseAll || !curated.list.length ? "" : `<button class="browse-stations" data-action="browse-stations">Browse all ${state.graph.stations.size} stations ›</button>`}`;
}

// MARK: - Events

function recordRecent(plan) {
  const entry = { origin: state.request.origin, destination: state.request.destination, summary: plan.walkOnly ? "walked" : `via ${routeTitle(plan)}`, time: Date.now() };
  state.recents = [entry, ...state.recents.filter(r => r.origin !== entry.origin || r.destination !== entry.destination)].slice(0, 5);
  store.set("pocketroute.recents", state.recents);
}

document.addEventListener("click", event => {
  const button = event.target.closest("button");
  if (!button || !state.graph) return;
  if (button.dataset.tab === "ask") { state.view = "route"; openAssistant(); return; }
  if (button.dataset.tab) { state.view = button.dataset.tab; if (state.view === "route") state.screen = "capture"; render(); return; }
  if (button.dataset.station) { chooseStation(button.dataset.station); return; }
  const { action, value } = button.dataset;
  switch (action) {
    case "offline-info": updateOfflineDialog(); offlineDialog.showModal(); break;
    case "open-menu": openMenu(); break;
    case "menu-tube": closeMenu(); state.view = "route"; state.screen = "capture"; render(); break;
    case "origin": askForLocation() || openPicker(true); break;
    case "close-dialog": { const d = button.closest("dialog"); d === menuDialog ? closeMenu() : d?.close(); break; }
    case "allow-location": store.set("pocketroute.locationAsked", true); locationDialog.close(); openPicker(true); locate(); break;
    case "skip-location": store.set("pocketroute.locationAsked", true); locationDialog.close(); openPicker(true); break;
    case "location-blocked": openLocationDialog("blocked"); break;
    case "retry-location": locationDialog.close(); checkPermission().then(() => { if (state.permission !== "denied") locate(); else openLocationDialog("blocked"); }); break;
    case "choose-station": locationDialog.close(); openPicker(true); break;
    case "install": install(); break;
    case "dismiss-install": state.install.dismissed = true; store.set("pocketroute.installDismissed", true); renderToasts(); break;
    case "reload": location.reload(); break;
    case "destination": openPicker(false); break;
    case "locate": locate(); break;
    case "browse-stations": state.picker.browseAll = true; populateStations(); break;
    case "situation": state.situations.has(value) ? state.situations.delete(value) : state.situations.add(value); render(); break;
    case "find": openAssistant(); break;
    case "expand": state.expanded.add(value); render(); break;
    case "choose-route": {
      const plan = state.thread.at(-1)?.plans.find(p => p.id === value) ?? state.thread.flatMap(e => e.plans).find(p => p.id === value);
      if (plan) { state.selected = plan; state.step = 0; state.screen = "guidance"; recordRecent(plan); render(); }
      break;
    }
    case "next":
      if (state.step + 1 < state.selected.legs.length) state.step++;
      else { state.selected = null; state.thread = []; state.situations.clear(); state.screen = "capture"; }
      render(); break;
    case "back": state.screen = state.screen === "guidance" ? "results" : "capture"; render(); break;
    case "ask": state.screen = "results"; render(); break;
    case "reroute": {
      const leg = state.selected?.legs[state.step];
      if (leg) { state.originId = leg.stops[0]; state.originConfirmed = true; state.onLine = leg.lineId; }
      startSearch(); break;
    }
    case "follow": sendMessage(value, { quick: true }); break;
    case "answer": chooseAnswer(value); break;
    case "answer-other": openPicker(state.awaiting !== "destination"); state.picker.answering = true; break;
    case "recent": {
      const recent = state.recents[Number(value)];
      if (recent) { state.originId = recent.origin; state.originConfirmed = true; state.destinationId = recent.destination; state.onLine = null; state.situations.clear(); state.view = "route"; startSearch(); }
      break;
    }
  }
});

// Single select: choosing a station applies it and closes the sheet.
function chooseStation(id) {
  const { origin } = state.picker;
  if (origin) {
    state.originId = id; state.originConfirmed = true;
    if (state.destinationId === id) state.destinationId = null;
    if (state.onLine && !state.graph.stations.get(id).lineIds.includes(state.onLine)) state.onLine = null;
  } else {
    state.destinationId = id;
  }
  dialog.close();
  // The picker answered the assistant's question.
  if (state.picker.answering) { state.picker.answering = false; if (origin) state.originId = null; else state.destinationId = null; chooseAnswer(id); return; }
  render();
  // Picking "I'm at" moves straight on to "Going to" when that's still empty.
  if (origin && !state.destinationId) openPicker(false);
}

// Tapping the dimmed area outside any half-screen sheet closes it.
for (const sheet of [dialog, offlineDialog, locationDialog]) {
  sheet.addEventListener("click", event => { if (event.target === sheet) sheet.close(); });
}

searchInput.addEventListener("input", populateStations);
document.addEventListener("submit", event => {
  if (event.target.id !== "follow-form" && event.target.id !== "describe-form") return;
  event.preventDefault();
  const text = new FormData(event.target).get("followup")?.trim();
  if (!text) return;
  // A new description on the first screen starts a new conversation.
  if (event.target.id === "describe-form") { state.thread = []; state.request = null; state.awaiting = null; state.constraints = null; }
  sendMessage(text);
});
document.addEventListener("change", event => {
  const { action } = event.target.dataset;
  if (action === "persist") requestPersistence();
  if (action === "stepfree") { state.prefs.stepFree = event.target.checked; store.set("pocketroute.stepFree", state.prefs.stepFree); }
  if (action === "on-line") { state.onLine = event.target.value || null; }
  if (action === "cloud") { state.prefs.cloud = event.target.checked; store.set("pocketroute.cloudAssist", state.prefs.cloud); }
});
window.addEventListener("online", () => { state.online = true; render(); });
window.addEventListener("offline", () => { state.online = false; render(); });

function updateOfflineDialog() {
  document.querySelector("#offline-title").textContent = state.online ? "You’re online" : "You’re offline";
  document.querySelector("#offline-last-signal").textContent = state.location.suggestion ? `Last known station · ${nameOf(state.location.suggestion)}` : "No recent location";
  document.querySelector("#offline-map-detail").textContent = `Tube map saved in this browser · ${savedDate()}`;
  const onDevice = state.ai.onDevice === "available", cloud = state.ai.configured && state.prefs.cloud && state.online;
  const ai = document.querySelector("#offline-ai");
  ai.className = `offline-feature ${onDevice || cloud ? "available" : "unavailable"}`;
  ai.querySelector("span").textContent = onDevice || cloud ? "✓" : "×";
  ai.querySelector("small").textContent = onDevice ? "Chrome’s model in this browser, no signal needed" : cloud ? "Gemini while you’re online; keywords offline" : "Station names, common phrases and quick replies";
}

async function boot() {
  render();
  try {
    const response = await fetch(DATA_URL);
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    state.graph = buildGraph(await response.json());
    state.matcher = createMatcher(state.graph);
  } catch (error) {
    state.loadError = "Open the app once with a connection to save the map for offline use.";
    render();
    return;
  }
  recomputeSuggestion();
  render();
  // Refresh the fix without prompting if permission was already given.
  await checkPermission();
  if (state.permission === "granted") locate();
  else if (state.permission === "denied") { state.location.status = "denied"; render(); }
  if (state.storage.supported) { state.storage.persisted = await navigator.storage.persisted().catch(() => false); render(); }
  state.ai.onDevice = await onDeviceStatus();
  if (navigator.onLine) state.ai.configured = await isConfigured();
  render();
}

// MARK: - Location permission
// Ask in our own sheet first, so the browser prompt only appears after the user chose to share.

async function checkPermission() {
  try {
    const status = await navigator.permissions?.query({ name: "geolocation" });
    if (!status) return;
    state.permission = status.state;
    status.onchange = () => {
      state.permission = status.state;
      if (status.state === "granted") locate();
      else if (status.state === "denied") { state.location.status = "denied"; render(); }
      else if (state.location.status === "denied") { state.location.status = "idle"; render(); }
    };
  } catch { /* Permissions API unsupported: treat as unknown */ }
}

/** Shows the ask sheet when location hasn't been asked for yet. Returns true when it did. */
function askForLocation() {
  if (!navigator.geolocation || state.permission === "granted" || state.permission === "denied") return false;
  if (store.get("pocketroute.locationAsked", false)) return false;
  openLocationDialog("ask");
  return true;
}

function openLocationDialog(variant) {
  const blocked = variant === "blocked";
  locationDialog.className = `permission-dialog ${blocked ? "blocked" : ""}`;
  locationDialog.innerHTML = `<header class="permission-head"><button class="sheet-close" data-action="close-dialog" aria-label="Close">${CLOSE_ICON}</button></header>
    <span class="permission-badge">${blocked ? LOCATION_OFF_ICON.replace(/18/g, "32") : PIN_ICON}</span>
    <h2 id="location-title">${blocked ? "Location is blocked" : "Find your nearest station"}</h2>
    ${blocked ? `<ol class="permission-steps"><li><span class="row-icon">${LOCK_ICON}</span>Tap the icon beside the address</li><li><span class="row-icon">${TOGGLE_ICON}</span>Set Location to Allow</li></ol>` : ""}
    <div class="permission-actions">
      <button class="primary" data-action="${blocked ? "choose-station" : "allow-location"}">${blocked ? "Choose station" : "Allow location"}</button>
      <button class="secondary-button" data-action="${blocked ? "retry-location" : "skip-location"}">${blocked ? "Try again" : "Choose station myself"}</button>
    </div>`;
  if (!locationDialog.open) locationDialog.showModal();
}

// MARK: - Install and updates

const isStandalone = () => matchMedia("(display-mode: standalone)").matches || navigator.standalone === true;
// iPhone and iPad Safari can't show an install prompt; people add the app from the Share menu.
const isIOS = () => /iphone|ipad|ipod/i.test(navigator.userAgent) || (navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1 && !("chrome" in window));
const canInstall = () => !isStandalone() && (!!state.install.prompt || isIOS());

async function install() {
  const prompt = state.install.prompt;
  if (!prompt) { state.install.dismissed = false; renderToasts(); return; } // iOS: show the Share hint
  state.install.prompt = null;
  prompt.prompt();
  await prompt.userChoice.catch(() => {});
  render();
}

window.addEventListener("beforeinstallprompt", event => { event.preventDefault(); state.install.prompt = event; render(); });
window.addEventListener("appinstalled", () => { state.install.prompt = null; render(); });

function renderToasts() {
  const items = [];
  if (state.updateReady) items.push(`<div class="toast" role="status"><span>New version ready</span><button class="pill-button accent" data-action="reload">Reload</button></div>`);
  const topLevel = state.view !== "route" || state.screen === "capture";
  if (!state.install.dismissed && topLevel && state.graph && canInstall()) {
    items.push(state.install.prompt
      ? `<div class="toast" role="status"><span>Install PocketRoute</span><button class="pill-button accent" data-action="install">Install</button><button class="toast-dismiss" data-action="dismiss-install" aria-label="Not now">${CLOSE_ICON}</button></div>`
      : `<div class="toast" role="status">${SHARE_ICON}<span>Share › Add to Home Screen</span><button class="toast-dismiss" data-action="dismiss-install" aria-label="Not now">${CLOSE_ICON}</button></div>`);
  }
  toasts.innerHTML = items.join("");
}

async function requestPersistence() {
  state.storage.persisted = await navigator.storage.persist().catch(() => false);
  render();
}

if ("serviceWorker" in navigator) window.addEventListener("load", () => {
  // A new service worker taking over an already-controlled page means a new version was saved.
  const hadController = !!navigator.serviceWorker.controller;
  navigator.serviceWorker.addEventListener("controllerchange", () => { if (hadController) { state.updateReady = true; renderToasts(); } });
  navigator.serviceWorker.register("/sw.js").catch(() => {});
});
boot();

// The send button is only active once there's something to send.
document.addEventListener("input", event => {
  if (event.target.name !== "followup") return;
  event.target.form.querySelector(".send").disabled = !event.target.value.trim();
});

// MARK: - Side menu drawer
// Slides in from the left, follows the finger: swipe from the left edge to
// open, swipe left (or tap outside, or Escape) to close.

const drawer = { startX: 0, startY: 0, startTime: 0, dx: 0, mode: null, dragged: false };
const reducedMotion = () => matchMedia("(prefers-reduced-motion: reduce)").matches;
const drawerWidth = () => menuDialog.getBoundingClientRect().width || 316;

function placeDrawer(x, animate) {
  menuDialog.style.transition = animate && !reducedMotion() ? "" : "none";
  menuDialog.style.transform = `translateX(${x}px)`;
}

function openMenu() {
  if (!menuDialog.open) { menuDialog.showModal(); placeDrawer(-drawerWidth(), false); menuDialog.getBoundingClientRect(); }
  placeDrawer(0, true);
}

function closeMenu() {
  if (!menuDialog.open) return;
  placeDrawer(-drawerWidth(), true);
  let done = false;
  const finish = () => { if (done) return; done = true; menuDialog.close(); menuDialog.style.transform = ""; };
  if (reducedMotion()) return finish();
  menuDialog.addEventListener("transitionend", finish, { once: true });
  setTimeout(finish, 400); // in case the transition never runs (background tab)
}

menuDialog.addEventListener("cancel", event => { event.preventDefault(); closeMenu(); });

// The drawer belongs to the top-level screens (the ones with the tab bar).
const drawerAvailable = () => state.graph && !document.querySelector(".tabs").hidden && !dialog.open && !offlineDialog.open && !locationDialog.open;

document.addEventListener("touchstart", event => {
  const t = event.touches[0];
  Object.assign(drawer, { startX: t.clientX, startY: t.clientY, startTime: event.timeStamp, dx: 0, mode: null, dragged: false });
  if (menuDialog.open) drawer.mode = "closing";
  else if (t.clientX < 24 && drawerAvailable()) drawer.mode = "opening";
}, { passive: true });

document.addEventListener("touchmove", event => {
  if (!drawer.mode) return;
  const t = event.touches[0], dx = t.clientX - drawer.startX, dy = t.clientY - drawer.startY;
  if (!drawer.dragged) {
    if (Math.abs(dx) < 10 || Math.abs(dx) < Math.abs(dy)) { if (Math.abs(dy) > 10) drawer.mode = null; return; }
    drawer.dragged = true;
    if (drawer.mode === "opening") menuDialog.showModal();
  }
  drawer.dx = dx;
  const w = drawerWidth();
  placeDrawer(drawer.mode === "opening" ? Math.min(0, dx - w) : Math.min(0, dx), false);
}, { passive: true });

document.addEventListener("touchend", event => {
  if (!drawer.mode || !drawer.dragged) { drawer.mode = null; return; }
  const w = drawerWidth(), velocity = drawer.dx / Math.max(1, event.timeStamp - drawer.startTime); // px per ms
  const shouldOpen = drawer.mode === "opening" ? (drawer.dx > w / 2 || velocity > 0.5) : !(drawer.dx < -w / 3 || velocity < -0.5);
  shouldOpen ? openMenu() : closeMenu();
  drawer.mode = null;
  setTimeout(() => { drawer.dragged = false; }, 0);
});
