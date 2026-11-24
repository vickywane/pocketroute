# AI interaction: re-routing on the downloaded map

This is how PocketRoute's assistant turns what a passenger types, says or taps into routes, with no signal. It applies the AI boundary in [architecture.md](architecture.md): the model reads the passenger's words, and the saved Tube map plus the route engine supply every fact.

## The pipeline

Every message takes the same path, whether it is typed, dictated or a quick-reply chip:

```
passenger's words
  → interpret   (Apple Intelligence, Gemini, or keyword rules)          → ParsedTurn: names and flags
  → ground      (drop anything the passenger never said)
  → plan        (match names to the saved map, ask if unsure)         → PlannedTurn: station ids, closures, questions
  → route       (deterministic RouteEngine over the saved map)        → RoutePlan cards
  → reply       (sentences built from map data; the model writes none of them)
```

| Stage | Code | Runs on | Can it invent facts? |
| --- | --- | --- | --- |
| Interpret | `AI/OnDeviceParser.swift`, `AI/CloudParser.swift`, `AI/PassengerTurn.swift` (`KeywordParser`) | Apple Foundation Models on device, Gemini through Firebase AI Logic, or plain Swift | It can try. Its output is only names and yes/no flags. |
| Ground | `Grounding.keepSaid` in `AI/RerouteAssistant.swift` | Swift | No. It removes any station or line name that isn't in the passenger's own words. |
| Plan | `TurnPlanner` in `AI/RerouteAssistant.swift`, `AI/StationMatcher.swift` | Swift | No. Every name is matched to an id in the saved map. |
| Route | `Routing/RouteEngine.swift` | Swift | No. |
| Reply | `RerouteSession.respond`, `RouteText` | Swift templates | No. |

## Interpreting a message

`ParsedTurn` holds everything a message can say about a trip:

- **Where:** `currentStation`, `destination`, `line` (the line the passenger is on), and `unassignedStation` for a bare name like "Euston".
- **What happened:** `situation` (held, terminating, line closed, missed stop) and `trainMoving`.
- **What's out:** `closedLines`, `closedSections` ("between Camden Town and Euston"), `closedStations` ("Bank is shut"), and `currentRouteBlocked` ("that branch isn't running").
- **Preferences:** `stepFree`, `walking`, `fewerChanges`.
- **Out of scope:** `asksForUnavailableInfo` for live status, delays, platforms or exits.

**On-device model.** `OnDeviceParser` sends one short request per message to `SystemLanguageModel.default` and uses guided generation (`@Generable ModelTurn`), so the result is always a typed value and never free text. The prompt holds only what the session already knows (stations, line, and a one-line summary of the route on screen), so it can make sense of "that branch" or "the change". No history is kept, so the context window never fills up. Sampling is greedy, and a request that takes longer than 6 s falls back to keyword rules.

**Gemini through Firebase AI Logic.** `CloudParser` asks Gemini for the same fields as JSON, constrained by a response schema, with minimal thinking. It runs only when the passenger has turned on *Use Gemini when online* in Settings, the phone has a network path, Firebase is configured, and Remote Config's `assistant_cloud_enabled` is true. `HybridInterpreter` tries Apple Intelligence first, then Gemini, then keyword rules; each model has a time limit and the answer never waits for a slow request. The reply is shown as "Understood by Gemini".

**Keyword rules.** `KeywordParser` reads the same fields with fixed rules. It runs:

- for every quick-reply chip, so a tap never waits for a model,
- on phones without Apple Intelligence, and in every test,
- alongside the model, where its reading is merged in so a flag the model missed ("step-free") is still caught.

**Grounding.** Before the model's reading is used, `Grounding.keepSaid` drops any station or line name that doesn't appear in what the passenger wrote. A typo fix ("warren st" becomes Warren Street) or a known alias ("kx") is kept. A destination or closure the model made up is dropped.

**Trusting flags.** Testing on the simulator showed the model raising extra flags. On the evaluation set it marked the line the passenger was on as closed, and their own origin or destination as closed stations (22/30 before the rules below, 29/30 after). For "trains not running between camden and euston" it also reported Euston as a closed station, said the current route was blocked, and treated the message as a live-info question. Together that left only the walking option. `Grounding.trustFlags` (and `trustFlags` in `apps/web/assistant.js`) now applies these rules:

- The end stations of a closed section are not treated as closed stations.
- "That route is blocked" is kept only when the keyword rules agree, and only when there is no explicit closure.
- "Asked for live info" is kept only when the keyword rules agree or the message contains a question mark.
- "The line is closed" gives way to an explicit closure ("between Camden and Euston" closes a section, not the whole line).
- A line reported closed, or named in a live-info question, isn't taken as the line the passenger is on.
- With no closure words in the message ("closed", "no trains", "avoid", …), every closure the model reported is dropped.
- The passenger's own stations, and the line they're on, aren't closed unless the keyword rules agree. Stations are compared by map id, so "Camden" and "Camden Town" are the same.
- "Fewer changes" needs the keyword rules or words about changing ("lifts only" isn't a request for a direct train).

**Fast paths.** Quick-reply chips and messages that are just one station name ("Camden Town") skip every model. They resolve instantly with the keyword rules.

## Planning against the map

`StationMatcher` is the only code that decides which station a name means. It matches in this order: exact name, name without the bracketed part ("Edgware Road (Circle Line)"), known aliases ("kx", "tcr", "st pancras"), whole-word prefix ("Camden" for Camden Town), then small typos (edit distance 1 to 2, depending on length). "Victoria" is a station unless it's followed by "line". "Bank branch" is a branch, not Bank station.

`TurnPlanner` turns names into ids and closures into `RerouteRequest` constraints:

- **Exactly one match:** the station is used and shown as a tag ("At Camden Town").
- **Several matches** ("Edgware Road", "Hammersmith"): the assistant asks "Which one?" with one-tap choices. The line the passenger is on decides when only one of the candidates is on it. It never guesses.
- **No match:** "I couldn't find 'Hogwarts' on the saved Tube map", with up to three similar spellings to tap.
- **Closed section:** turned into segment keys on every regular service that runs between the two stations (`NetworkGraph.segmentKeys`).
- **Closed station:** trains may run through it, but no route changes, walks or gets off there (`RerouteRequest.avoidStations`).
- **"That branch isn't running":** the first ride of the route on screen is avoided. If that leaves no way out of the station, the first hop is put back.

## The conversation

A conversation can start in three ways:

1. **The form** (stations, line and situation tiles, then *Find another way*). This works exactly as before and needs no AI.
2. **One sentence** on the first screen, typed or spoken: "Held at Camden on the Northern, need Warren St". The assistant fills in what it can. If both stations are known it shows routes straight away. If not, it asks for the missing one.
3. **Re-route from guidance** ("Something's wrong"). This starts again from the current step.

Each turn of the thread shows:

- **The passenger's message**, with an *Understood* row underneath: tags for what was taken from it ("At Camden Town", "No Victoria line", "Step-free") and who read it ("Understood on this iPhone" or "Matched by keywords"). A wrong reading is visible at a glance and can be fixed with one more message.
- **A reply** built from templates and map data. While the model is working, the reply area shows "Reading that against the saved map…".
- **One of three things:** route cards; one-tap station choices, plus *Another station* to open the full picker; or nothing, when the message changed nothing (the reply then says so).

What the assistant says in each case:

| Passenger says | Assistant does |
| --- | --- |
| "I'm going to Warren Street" (no origin) | Asks "Which station are you at now?" with stations on their line as choices. |
| "Euston" (after a question) | Uses it to answer the question. |
| "the Victoria line is closed" | Avoids the line, says so, and shows new routes. |
| "no trains between Camden and Euston" | Avoids that section of the Northern line. |
| "I'm at Edgware Road" | Asks which Edgware Road, with the lines at each. |
| "when will it move?" / "which platform?" | Says it can't see live service, delays or platforms offline, and keeps the routes. |
| "what about the weather" | Says it didn't catch a change, keeps the routes, and gives example phrases. |

## Availability and settings

`AssistantAvailability.current` reads `SystemLanguageModel.default.availability`:

| State | Shown as | Behaviour |
| --- | --- | --- |
| Available, language supported | "On this iPhone" | Model plus keywords; Gemini if the model fails and Gemini is on. |
| Device not eligible | "Keywords only" | Gemini when on and online, otherwise keywords. |
| Apple Intelligence off | "Apple Intelligence off" | Keywords, with a hint to turn it on. |
| Model still downloading | "Getting ready" | Keywords. |

Settings → Assistant shows this state and the *Use Gemini when online* switch (off by default). The offline sheet says which reader is active. The form flow works on every phone.

## The web client

`apps/web/assistant.js` ports `StationMatcher`, `KeywordParser`, grounding, flag trust and `TurnPlanner`, so the PWA has the same one-sentence start, follow-ups, questions with choices and "understood" tags. `apps/web/firebase-ai.js` adds a model through Firebase AI Logic's hybrid mode: Chrome's built-in model in the browser when it's available (no data leaves the device), with Gemini as the cloud fallback when the passenger has turned it on. Both use the same JSON schema. The SDK loads only when a model is wanted, and the service worker keeps it for offline use.

## Evaluation

`shared/fixtures/assistant-eval.json` holds 30 labelled messages. `AssistantEvalTests.swift` and `assistant.test.mjs` score each reader against it field by field: fields a case lists must match, and station or closure fields it leaves out must stay empty, so an invented station fails. Keyword rules must keep at least 29/30. The Apple Intelligence run happens on devices where the model is available; the Gemini run happens when `POCKETROUTE_EVAL_GEMINI=1` is passed to the test runner.

## Not built yet

- Voice input in the PWA.
- Apple Intelligence results on a physical iPhone (the simulator scores 29/30).
