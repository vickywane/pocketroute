# Architecture

## Product boundary

PockerRouter is an offline re-routing assistant for London Underground passengers who lose signal when their journey is disrupted (a held train, a train terminating early, a closed line or branch, a missed stop). It is not a primary journey planner.

The app answers one question: "From where I am now, how do I get to where I'm going?" It answers using an offline copy of the Tube network on the device. Connectivity is only used to refresh that network data and, optionally, for cloud model fallback.

## Core flow

1. **Situation capture:** current station, destination, the line and direction the user was on, and what happened. This is collected by taps (station picker, situation tiles) or by free text and voice.
2. **Intent extraction (AI):** the model turns the user's message into a typed `RerouteRequest`.
3. **Route search (deterministic):** the route engine searches the offline network graph and returns ranked `RouteOption`s.
4. **Response rendering:** route cards and step-by-step guidance are rendered from `RouteOption` data. The model may write the short connecting sentence around them, but never the route facts.
5. **Follow-ups:** quick replies ("branch isn't running", "train is moving again", "step-free only") update the `RerouteRequest` constraints and rerun the search from the user's current position.

## Offline network graph

- Nodes: stations, with platforms and step-free flags where the source data supports them.
- Edges: line segments (line, branch, direction, order of stops, typical run time), interchanges within a station (with typical transfer time), and walking links between nearby stations (distance and estimated time).
- Branches are modelled explicitly (for example, the Northern line's Bank and Charing Cross branches meet at Camden Town and Kennington), because many re-routes depend on them.
- Each network snapshot is versioned and records its source, licence and retrieval date. The app shows the snapshot date to the user ("Tube map saved on this iPhone · 14 Nov").
- The source-generated TfL snapshot is in `shared/fixtures/london-underground-network-v1.json`; rebuild it with `tools/build_tfl_network.py`. The separate `demo-journey.json` fixture remains illustrative. Confirm current TfL API terms and attribution before production use.

## AI boundary

The model's job is to understand the user and to phrase answers. It is not a source of route facts.

- **Input schema (`RerouteRequest`):** `currentStation`, `destination`, `onLine`, `direction`, `situation` (held, terminating, lineClosed, missedStop, other), `avoid` (lines, branches or stations the user reports as unavailable), and `preferences` (stepFree, fewestChanges, willingToWalk).
- Station and line names produced by the model are resolved against the local graph. Unknown or ambiguous names lead to a clarifying question with tappable choices, never a guess.
- The model must not invent stations, platforms, exits, disruptions or live service information. Current conditions come only from what the user reports.
- Every answer shown to the user cites its source ("From your saved Tube map · no live service info").

## Location without GPS

GPS does not work underground. The app records the last station where the phone had signal or a location fix, and offers it as the default "I'm at" station. The station picker lists stations on the user's line in order, so correcting it is a single tap.

## Client implementations

- **iOS:** SwiftUI and Swift 6, designed for large tap targets, one-handed use and Dynamic Type. The intended native speech path is on-device speech recognition.
- **PWA:** static web client with an installable manifest and service worker for caching the application shell. Voice input is omitted. Browser geolocation provides an optional nearby-station suggestion; the user confirms the station because GPS is often unavailable underground.
- Both clients route on the TfL snapshot. The deterministic engine (`apps/ios/PockerRouter/Routing/RouteEngine.swift`, mirrored in `apps/web/route-engine.js`) runs a Dijkstra search over (station, line, previous stop) states, so it knows when one train can continue through a junction and when the passenger must change trains (for example between the Northern line's branches). It returns the fastest plan, a fewest-changes plan when different, an alternative when only one exists, and a walking option within 40 minutes.
- Messages (typed, spoken or chips) are read into a `ParsedTurn` by Apple Foundation Models on device when available, or by keyword rules otherwise; the model's reading is grounded against the passenger's words, names are resolved against the saved map, and ambiguous or unknown stations become a question with tappable choices. See [AI interaction](ai-interaction.md).
- Location: the last good fix (accuracy ≤ 1 km, kept for 12 hours) is matched against whichever map is loaded and re-matched when a new map loads. A suggestion within 2 km becomes the default "I'm at" station until the passenger picks one themselves.
- The iOS app keeps the downloaded map at a path relative to Application Support (iOS can move the app container on update), deletes superseded versions, and can retry a failed download. The iOS app runs Apple Foundation Models on device for message understanding; neither client runs Firebase AI Logic (Gemini) inference yet.
- Gemini cloud fallback through Firebase AI Logic remains planned (off by default), as does Chrome's Prompt API on supported desktop web. Both platform APIs have compatibility limits described in their setup guides.
- Store the production network snapshot and current re-routing session locally on each platform (versioned JSON first; SwiftData can follow on iOS, browser storage on web).

## Fallback when AI is unavailable

If no model can run (unsupported device, Apple Intelligence disabled, no connection for cloud fallback), the tap-based flow still works end to end: station picker → situation tiles → route cards → step-by-step guidance. Free-text and voice input are hidden or limited to simple keyword matching against station names.

## Firebase responsibilities

Firebase AI Logic powers the cloud fallback and hybrid orchestration from the client. App Check protects eligible Firebase requests. Crashlytics and Analytics are optional later additions, subject to privacy review. Firestore is not needed: the core re-routing flow must never depend on a network database.
