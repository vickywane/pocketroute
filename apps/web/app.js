const stations = [
  ["Kentish Town", 51.5507, -0.1402], ["Camden Town", 51.5392, -0.1426], ["Euston", 51.5282, -0.1337],
  ["King’s Cross St Pancras", 51.5308, -0.1238], ["Angel", 51.5322, -0.1058], ["Warren Street", 51.5247, -0.1384],
  ["Oxford Circus", 51.5152, -0.1419], ["Bank", 51.5133, -0.0886],
  ["Waterloo", 51.5036, -0.1143], ["Victoria", 51.4965, -0.1447], ["Tottenham Court Road", 51.5165, -0.1309],
  ["Leicester Square", 51.5113, -0.1281], ["Goodge Street", 51.5206, -0.1347], ["Mornington Crescent", 51.5342, -0.1387],
  ["London Bridge", 51.5055, -0.0860], ["Piccadilly Circus", 51.5098, -0.1342]
];

const routeOptions = [
  { title: "Charing Cross branch", lines: ["Northern"], detail: "3 stops · change platforms here", minutes: 7, badge: "Fastest", steps: ["Change to the Charing Cross branch at Camden Town", "Stay on through Mornington Crescent to Euston", "Change to the Victoria line for one stop to Warren Street"] },
  { title: "Via Euston and Victoria line", lines: ["Northern", "Victoria"], detail: "2 stops · change at Euston", minutes: 9, steps: ["Stay on the Northern line to Euston", "Change to the Victoria line southbound", "Get off at Warren Street"] },
  { title: "Walk instead", lines: ["Walk"], detail: "2.1 km · leave the station", minutes: 27, steps: ["Leave Camden Town station", "Walk south toward Warren Street", "Arrive at Warren Street"] }
];

const state = {
  view: "route", origin: "Camden Town", destination: "Warren Street",
  selected: null, step: 0, locationText: "Use your last known station underground",
  locationSuggestion: null, stepFree: false, suggestWalking: true, useCloudAI: false, dropBranch: false, pickingOrigin: true,
  disruptions: new Set(), pendingStation: null, browseAll: false
};
const app = document.querySelector("#app");
const dialog = document.querySelector("#station-dialog");
const offlineDialog = document.querySelector("#offline-dialog");
const pickerTitle = document.querySelector("#picker-title");
const searchInput = document.querySelector("#station-search");
const stationList = document.querySelector("#station-list");
const esc = value => String(value).replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);

function render() {
  const hideTabs = state.view === "results";
  document.querySelector(".tabs").hidden = hideTabs;
  document.querySelectorAll(".tab").forEach(button => button.classList.toggle("active", button.dataset.tab === (state.view === "results" ? "route" : state.view)));
  if (state.view === "saved") return renderSaved();
  if (state.view === "settings") return renderSettings();
  if (state.view === "results") return state.selected ? renderGuidance() : renderResults();
  renderCapture();
}

function header() {
  return `<header class="screen-header"><button aria-label="Back" data-action="back">‹</button><div><strong>${esc(state.origin)} → ${esc(state.destination)}</strong><small>Saved map · demo route data</small></div><span style="width:42px"></span></header>`;
}

function capture() {
  return `<section class="screen stack">
    <button class="pill offline-banner" data-action="offline-info" aria-haspopup="dialog">⌁ <strong>Offline</strong><span>· Tube map saved 14 Nov</span><span aria-hidden="true">›</span></button>
    <h1 class="hero">Train stopped?<br>Let’s find another way.</h1>
    <div class="card">
      <button class="station-row" data-action="origin"><span class="row-icon">◎</span><span><span class="label">I’m at</span><br><strong>${esc(state.origin)}</strong></span><span class="chevron">›</span></button><div class="divider"></div>
      <button class="station-row" data-action="destination"><span class="row-icon">⚑</span><span><span class="label">Going to</span><br><strong>${esc(state.destination)}</strong></span><span class="chevron">›</span></button><div class="divider"></div>
      <div class="station-row"><span class="row-icon">▤</span><span><span class="label">I was on</span><br><strong><span class="line-tag northern">Northern</span> Morden via Bank</strong></span><span class="chevron">›</span></div>
    </div>
    <h2 class="section-title">What happened?</h2>
    <div class="situations">${[["Train held", "Ⅱ"], ["Terminating here", "⊟"], ["Line closed", "⊗"], ["Missed my stop", "⇥"]].map(([name, glyph]) => `<button class="situation ${state.disruptions.has(name) ? "selected" : ""}" data-action="situation" data-value="${esc(name)}"><span class="glyph">${state.disruptions.has(name) ? "✓" : name === "Train held" ? "" : glyph}</span><span>${name}</span></button>`).join("")}</div>
    <button class="primary" data-action="find">Find another way</button>
  </section>`;
}

function renderCapture() { app.innerHTML = capture(); }
function visibleRoutes() { return routeOptions.filter(route => (!state.stepFree || route.title !== "Walk instead") && (state.suggestWalking || route.title !== "Walk instead") && (!state.dropBranch || route.title !== "Charing Cross branch")); }

function routeCard(route) {
  return `<button class="route-card ${route.badge ? "recommended" : ""}" data-action="choose-route" data-value="${esc(route.title)}"><span class="route-top"><span class="route-copy"><span class="route-name">${esc(route.title)}</span><span class="line-tags">${route.lines.map(line => `<span class="line-tag ${line.toLowerCase()}">${line}</span>`).join("")}${route.badge ? `<span class="badge">${route.badge}</span>` : ""}</span></span><span class="eta">${route.minutes}<small>min</small></span><span class="chevron">›</span></span><span class="route-detail">${esc(route.detail)}</span></button>`;
}

function renderResults() {
  const report = state.disruptions.size ? `Reported: ${[...state.disruptions].join(", ")}.` : "My journey has changed.";
  app.innerHTML = `<section class="screen stack results-screen">${header()}<div class="thread">
    <div class="user-message"><div class="bubble user">I’m on the Northern line to Morden via Bank. The train’s stopped at ${esc(state.origin)}. ${esc(report)} How do I get to ${esc(state.destination)}?</div><small>⌁ &nbsp;Typed · on this device</small></div>
    <div class="assistant-message"><span class="assistant-mark">✦</span><div class="bubble">There are ${visibleRoutes().length} ways to ${esc(state.destination)} from here:</div></div>
    ${visibleRoutes().map(routeCard).join("")}
    <p class="source-note">ⓘ Example data · no live service information</p>
  </div></section>
  <div class="composer"><div class="chips"><button class="chip" data-action="follow" data-value="Train is moving again">Train is moving again</button><button class="chip" data-action="follow" data-value="Branch isn’t running">Branch isn’t running</button><button class="chip" data-action="follow" data-value="Step-free only">Step-free only</button></div>
  <form class="compose-row" id="follow-form"><input name="followup" placeholder="Type a follow-up" aria-label="Type a follow-up"/><button class="send" aria-label="Send">↑</button></form></div>`;
}

function renderGuidance() {
  const route = routeOptions.find(option => option.title === state.selected);
  if (!route) { state.selected = null; state.view = "results"; return renderResults(); }
  const index = Math.min(state.step, route.steps.length - 1);
  app.innerHTML = `<section class="screen stack guidance-screen"><header class="guidance-header"><button data-action="back">Close</button><strong>To ${esc(state.destination)}</strong><button data-action="ask">Ask</button></header><div class="guidance-body">
    <div class="step-count"><span>Step ${index + 1} of ${route.steps.length}</span><small>~${Math.max(route.minutes - index * 3, 1)} min to go</small></div><div class="progress-track"><i style="width:${((index + 1) / route.steps.length) * 100}%"></i><i style="width:${index / route.steps.length * 100}%"></i><i></i></div>
    <article class="step-card"><span class="step-symbol">↕</span><h1 class="instruction">${esc(route.steps[index])}</h1><p>${esc(index === 0 ? "Follow the signs to the platform shown on your saved Tube map." : route.steps[index])}</p><div class="next-line"><span class="line-tag ${route.lines[Math.min(index, route.lines.length - 1)].toLowerCase()}">${route.lines[Math.min(index, route.lines.length - 1)]}</span><div><strong>${index + 1 < route.steps.length ? "Next: " + esc(route.steps[index + 1]) : "You’ve arrived"}</strong><small>${esc(route.title)} · saved map route</small></div></div></article>
    <div class="guidance-actions"><button class="primary" data-action="next">${index + 1 < route.steps.length ? "I’m on the train" : "Arrived · Finish"}</button><button class="secondary-button" data-action="reroute">⟳ &nbsp; Something’s wrong — find another way</button></div>
  </div></section>`;
}

function renderSaved() {
  app.innerHTML = `<section class="screen stack saved-screen"><div class="saved-heading"><h1>Saved</h1><button class="add-place" data-action="add-place" aria-label="Add place">+</button></div><div class="settings-group"><h2>Places</h2><div class="card saved-places"><button class="place-row" data-action="use-place" data-value="Kentish Town"><span class="row-icon">⌂</span><span><strong>Home</strong><small>Kentish Town</small></span><b>Go</b></button><button class="place-row" data-action="use-place" data-value="Warren Street"><span class="row-icon">▣</span><span><strong>Work</strong><small>Warren Street</small></span><b>Go</b></button></div></div><div class="settings-group"><h2>Recent re-routes</h2><div class="card recent-list"><button class="recent-row" data-action="recent"><span class="recent-icon">◷</span><span><strong>Camden Town → Warren Street</strong><small>Today 08:45 · via Euston and Victoria line</small></span><span>›</span></button><button class="recent-row" data-action="recent"><span class="recent-icon">◷</span><span><strong>Bank → King’s Cross</strong><small>Tue · walked from Moorgate</small></span><span>›</span></button></div></div><p class="saved-note">⌂ &nbsp; Saved on this iPhone only<br><small>Create an account to back up your places. You can do it when you’re back online.</small></p></section>`;
}

function settingGroup(title, rows) {
  return `<div class="settings-group"><h2>${title}</h2><div class="card">${rows.map(([icon, name, description, trailing]) => `<div class="setting"><span class="row-icon">${icon}</span><span class="setting-copy"><strong>${name}</strong><small>${description}</small></span>${trailing || ""}</div>`).join("")}</div></div>`;
}

function renderSettings() {
  app.innerHTML = `<section class="screen settings-screen stack"><div class="pill online">⌁ <strong>Online</strong><span>· demo map data</span><span>›</span></div><h1 class="settings-title">Settings</h1>
    <article class="account-card"><div class="account-overview"><span class="account-avatar">♙</span><div><strong>You’re using a guest profile</strong><small>Everything works without an account. Saved places stay on this device.</small></div></div><div class="account-benefits"><div>✓ &nbsp; Back up saved places and journeys</div><div>✓ &nbsp; Keep your places on this device</div></div><div class="account-actions"><button class="soft-button" data-action="account">Sign in</button><button class="primary" data-action="account">Create account</button></div></article>
    ${settingGroup("Offline data", [["◫", "Tube map", `Demo station sample · ${stations.length} stations`, `<b class="status-good">Saved</b>`], ["⟳", "Update automatically", "Map updates aren’t connected in this prototype"]])}
    ${settingGroup("AI & voice", [["✧", "On-device AI", "AI integration isn’t connected yet", `<b>Not set up</b>`], ["☁", "Use cloud AI when online", "Cloud model isn’t connected in this prototype"]])}
    <div class="settings-group"><h2>Routes</h2><div class="card"><label class="setting"><span class="row-icon">♿</span><span class="setting-copy"><strong>Step-free routes first</strong></span><input type="checkbox" data-action="stepfree" ${state.stepFree ? "checked" : ""}/></label><label class="setting"><span class="row-icon">♙</span><span class="setting-copy"><strong>Suggest walking</strong><small>Up to 30 minutes</small></span><input type="checkbox" data-action="walking" ${state.suggestWalking ? "checked" : ""}/></label></div></div>
    ${settingGroup("About", [["◈", "Privacy", "Location is only used to suggest a station", "›"], ["ⓘ", "Map data & licences", "Demo station sample · not live TfL data", "›"]])}<small class="version-note">PocketRoute 1.0</small></section>`;
}

function openPicker(isOrigin) {
  state.pickingOrigin = isOrigin;
  state.pendingStation = isOrigin ? state.origin : state.destination;
  pickerTitle.textContent = isOrigin ? "Where are you?" : "Where are you going?";
  searchInput.value = "";
  populateStations();
  dialog.showModal();
}

function populateStations() {
  const query = searchInput.value.trim().toLowerCase();
  const selected = state.pendingStation;
  const pool = stations.map(([name]) => name).filter(name => name.toLowerCase().includes(query));
  const nearby = state.locationSuggestion ? `<button class="nearby-choice" data-station="${esc(state.locationSuggestion)}">◎ &nbsp; Use nearby · ${esc(state.locationSuggestion)}</button>` : `<button class="nearby-choice" data-action="locate">◎ &nbsp; ${esc(state.locationText)}</button>`;
  const lineStations = ["Kentish Town", "Camden Town", "Euston", "King’s Cross St Pancras", "Angel"];
  const curated = query || state.browseAll ? pool : lineStations;
  stationList.innerHTML = `<p class="picker-tip">ⓘ &nbsp; Not sure? Look for the station name on the platform wall.</p>${nearby}<p class="picker-section">${query || state.browseAll ? "Stations" : "On your line · Northern, Bank branch"}</p><div class="picker-line-list">${curated.map((name, i) => `<button class="station-choice" data-station="${esc(name)}" aria-selected="${name === selected}"><span class="line-dot ${name === selected ? "current" : ""}"></span><span class="station-copy">${esc(name)}${name === selected ? `<small>Last place your phone had signal</small>` : i === 2 ? `<small>Change for Victoria line</small>` : ""}</span><span>${name === selected ? "✓" : ""}</span></button>`).join("")}</div>${query || state.browseAll ? "" : `<p class="picker-section">Not on my line</p><button class="browse-stations" data-action="browse-stations">Browse all ${stations.length} demo stations ›</button>`}`;
}

function findNearby() {
  state.locationText = "Requesting location permission…";
  if (!dialog.open) { render(); return; }
  if (!navigator.geolocation) { state.locationText = "Location isn’t available in this browser. Choose a station manually."; return dialog.open ? populateStations() : render(); }
  navigator.geolocation.getCurrentPosition(position => {
    const { latitude, longitude } = position.coords;
    const distance = station => {
      const radians = degrees => degrees * Math.PI / 180;
      const dLat = radians(station[1] - latitude), dLon = radians(station[2] - longitude);
      const a = Math.sin(dLat / 2) ** 2 + Math.cos(radians(latitude)) * Math.cos(radians(station[1])) * Math.sin(dLon / 2) ** 2;
      return 6371000 * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
    };
    const nearest = stations.reduce((best, station) => distance(station) < distance(best) ? station : best, stations[0]);
    if (distance(nearest) > 2000) {
      state.locationSuggestion = null;
      state.locationText = "You’re outside this demo’s station sample. Choose a station manually.";
      return dialog.open ? populateStations() : render();
    }
    state.locationSuggestion = nearest[0];
    state.origin = nearest[0];
    state.pendingStation = nearest[0];
    state.locationText = `Nearby suggestion: ${nearest[0]} · confirm the station`;
    if (dialog.open) populateStations(); else render();
  }, () => { state.locationText = "Couldn’t get a fix. GPS may drop underground; choose your station."; if (dialog.open) populateStations(); else render(); }, { enableHighAccuracy: true, timeout: 8000, maximumAge: 300000 });
}

function applyFollowUp(text) {
  const normalized = text.toLowerCase();
  if (normalized.includes("step-free")) state.stepFree = true;
  if (normalized.includes("branch")) state.dropBranch = true;
  if (normalized.includes("moving")) state.disruptions.delete("Train held");
  state.selected = null;
  state.view = "results";
  render();
}

document.addEventListener("click", event => {
  const button = event.target.closest("button");
  if (button?.dataset.tab) { state.view = button.dataset.tab; state.selected = null; render(); return; }
  if (button?.dataset.station) {
    state.pendingStation = button.dataset.station;
    populateStations(); return;
  }
  if (!button?.dataset.action) return;
  const { action, value } = button.dataset;
  if (action === "offline-info") {
    document.querySelector("#offline-last-signal").textContent = `Last known station · ${state.origin}`;
    offlineDialog.showModal();
  }
  if (action === "dismiss-offline") offlineDialog.close();
  if (action === "origin") openPicker(true);
  if (action === "destination") openPicker(false);
  if (action === "locate") findNearby();
  if (action === "browse-stations") { state.browseAll = true; populateStations(); }
  if (action === "situation") { state.disruptions.has(value) ? state.disruptions.delete(value) : state.disruptions.add(value); render(); }
  if (action === "find") { state.view = "results"; state.selected = null; render(); }
  if (action === "choose-route") { state.view = "results"; state.selected = value; state.step = 0; render(); }
  if (action === "next") {
    const route = routeOptions.find(option => option.title === state.selected);
    if (state.step + 1 < (route?.steps.length || 0)) { state.step++; render(); }
    else { state.selected = null; renderResults(); }
  }
  if (action === "back") { if (state.selected) { state.selected = null; render(); } else { state.view = "route"; render(); } }
  if (action === "ask") { state.selected = null; state.view = "results"; render(); }
  if (action === "reroute") { state.selected = null; render(); }
  if (action === "follow") applyFollowUp(value);
  if (action === "settings") { state.view = "settings"; render(); }
  if (action === "walking") { state.suggestWalking = button.checked; }
  if (action === "account") window.alert("Account setup isn’t connected in this prototype.");
  if (action === "add-place") window.alert("Saved places are sample data in this prototype.");
  if (action === "use-place") { state.destination = value; state.view = "route"; state.selected = null; render(); }
  if (action === "recent") { state.origin = "Camden Town"; state.destination = "Warren Street"; state.view = "results"; state.selected = null; render(); }
});

document.querySelector("#picker-cancel").addEventListener("click", event => { event.preventDefault(); dialog.close(); });
document.querySelector("#picker-done").addEventListener("click", event => {
  event.preventDefault();
  if (state.pickingOrigin) state.origin = state.pendingStation; else state.destination = state.pendingStation;
  state.locationSuggestion = null;
  dialog.close(); render();
});

searchInput.addEventListener("input", populateStations);
dialog.addEventListener("close", () => { state.browseAll = false; });
document.addEventListener("submit", event => {
  if (event.target.id !== "follow-form") return;
  event.preventDefault();
  applyFollowUp(new FormData(event.target).get("followup") || "");
});
document.addEventListener("change", event => { if (event.target.dataset.action === "stepfree") state.stepFree = event.target.checked; if (event.target.dataset.action === "walking") state.suggestWalking = event.target.checked; });
if ("serviceWorker" in navigator) window.addEventListener("load", () => navigator.serviceWorker.register("/sw.js").catch(() => {}));
render();
