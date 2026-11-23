# AI interaction: re-routing on the downloaded map

This is how PocketRoute's assistant turns what a passenger types, says or taps into routes, with no signal. It applies the AI boundary in [architecture.md](architecture.md): the model reads the passenger's words, and the saved Tube map plus the route engine supply every fact.

## The pipeline

Every message takes the same path, whether it is typed, dictated or a quick-reply chip:

```
passenger's words
  → interpret   (Apple Intelligence on device, or keyword rules)      → ParsedTurn: names and flags
  → ground      (drop anything the passenger never said)
  → plan        (match names to the saved map, ask if unsure)         → PlannedTurn: station ids, closures, questions
  → route       (deterministic RouteEngine over the saved map)        → RoutePlan cards
  → reply       (sentences built from map data; the model writes none of them)
```

| Stage | Code | Runs on | Can it invent facts? |
| --- | --- | --- | --- |
| Interpret | `AI/OnDeviceParser.swift`, `AI/PassengerTurn.swift` (`KeywordParser`) | Apple Foundation Models on device, or plain Swift | It can try. Its output is only names and yes/no flags. |
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

**Keyword rules.** `KeywordParser` reads the same fields with fixed rules. It runs:

- for every quick-reply chip, so a tap never waits for a model,
- on phones without Apple Intelligence, and in every test,
- alongside the model, where its reading is merged in so a flag the model missed ("step-free") is still caught.

**Grounding.** Before the model's reading is used, `Grounding.keepSaid` drops any station or line name that doesn't appear in what the passenger wrote. A typo fix ("warren st" becomes Warren Street) or a known alias ("kx") is kept. A destination or closure the model made up is dropped.

**Trusting flags.** Testing on the simulator showed the model raising extra flags. For "trains not running between camden and euston" it also reported Euston as a closed station, said the current route was blocked, and treated the message as a live-info question. Together that left only the walking option. `Grounding.trustFlags` now applies three rules:

- The end stations of a closed section are not treated as closed stations.
- "That route is blocked" is kept only when the keyword rules agree, and only when there is no explicit closure.
- "Asked for live info" is kept only when the keyword rules agree or the message contains a question mark.

**Fast paths.** Quick-reply chips and messages that are just one station name ("Camden Town") skip the model. They resolve instantly with the keyword rules.

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
| Available, language supported | "On this iPhone" | Model plus keywords. |
| Device not eligible | "Keywords only" | Keywords. |
| Apple Intelligence off | "Apple Intelligence off" | Keywords, with a hint to turn it on. |
| Model still downloading | "Getting ready" | Keywords. |

Settings → AI & voice and the offline sheet show this state. The form flow works on every phone.

## Not built yet

- **Gemini cloud fallback** through Firebase AI Logic, off by default as planned. `TurnInterpreting` is the place to add it. It would use the same grounding and planner, and only run when the passenger is online and has opted in.
- **PWA parity:** the web client still matches only its quick replies. Porting `StationMatcher` and `KeywordParser` to JavaScript would give it the same one-sentence start without a model.
- **Model evaluation:** keyword rules have unit tests. The on-device model needs a device with Apple Intelligence, so the next step is a labelled set of passenger messages, run on a device, that checks each `ParsedTurn` field.
