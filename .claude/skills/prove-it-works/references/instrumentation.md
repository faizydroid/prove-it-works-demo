# Instrumenting the app

Three edits per app, in this order. Use the environment key the app already uses for flags; it
accepts both client-side and server-side keys for events. Client-side keys are public by design
(they ship to every browser) and can live in the app's config. Server-side keys (`ser.…`) and admin
keys belong in environment variables, never in git.

A browser app loaded without a bundler can import the SDK as an ES module:
`import flagsmith from 'https://cdn.jsdelivr.net/npm/@flagsmith/flagsmith@12.6.0/index.mjs';`

**Minimum SDK versions that can send events.** Older SDKs silently can't; upgrade or stop.

| Stack | Package | Min version |
|---|---|---|
| JavaScript / React / SSR | `@flagsmith/flagsmith` | 12.4.0 |
| Python | `flagsmith` | 6.3.0 |
| Java | `com.flagsmith:flagsmith-java-client` | 8.2.0 |
| Node.js | `@flagsmith/nodejs` (the old `flagsmith-nodejs` cannot) | 9.1.0 |
| Go | `github.com/Flagsmith/flagsmith-go-client/v5` | 5.3.0 |
| Flutter | `flagsmith` | 6.2.0 |

Self-hosted: also pass the API URL (`https://host/api/v1/`) and the events URL. If events go to the
Flagsmith API itself (no separate ingestion service), the events URL is the API URL ending in `/api/`.

## 1. Initialise with events on

```js
// JavaScript (browser or SSR)
import flagsmith from '@flagsmith/flagsmith';
await flagsmith.init({ environmentID: KEY, identity: userId, enableEvents: true });
// self-hosted: api: 'https://host/api/v1/', eventProcessorConfig: { eventsApiUrl: 'https://host/api/' }
```
```jsx
// React
<FlagsmithProvider flagsmith={flagsmith} options={{ environmentID: KEY, identity: userId, enableEvents: true }}>
```
```python
# Python
from flagsmith import Flagsmith, EventProcessorConfig
flagsmith = Flagsmith(environment_key=KEY, enable_events=True)
# short-lived scripts: event_processor_config=EventProcessorConfig(max_buffer_items=1)
```
```java
// Java
FlagsmithClient flagsmith = FlagsmithClient.newBuilder().setApiKey(KEY)
    .withConfiguration(FlagsmithConfig.newBuilder().withEnableEvents(true).build()).build();
```
```js
// Node.js
import { Flagsmith } from '@flagsmith/nodejs';
const flagsmith = new Flagsmith({ environmentKey: KEY, enableEvents: true });
```
```go
// Go
eventsCtx, stopEvents := context.WithCancel(context.Background())
client := flagsmith.NewClient(KEY, flagsmith.WithEvents(eventsCtx))
```
```dart
// Flutter
final flagsmith = await FlagsmithClient.init(apiKey: KEY, config: const FlagsmithConfig(enableEvents: true));
```

## 2. Exposure: the experiment-flag call, where the variation is seen

Identify first (same identifier you'll use for events). The call evaluates the flag **and** records
the exposure, so put it where the user actually experiences the change, and render by `value`.

```js
const flag = flagsmith.getExperimentFlag('<flag>');            // JS: after init/identify
const flag = useExperiment('<flag>');                          // React hook; null until loaded
flag = flagsmith.get_experiment_flag("<flag>", identifier=uid) # Python
BaseFlag flag = flagsmith.getExperimentFlag("<flag>", uid);    // Java
const flag = await flagsmith.getExperimentFlag('<flag>', uid); // Node.js
flag, err := client.GetExperimentFlag(ctx, "<flag>", flagsmith.NewEvaluationContext(uid, nil)) // Go
final flag = await flagsmith.getExperimentFlag('<flag>', user: Identity(identifier: uid)); // Flutter
```

Evaluate here, display elsewhere? Use the normal flag call (records nothing) and record the exposure
yourself at the point of display, only for enrolled identities:

```js
const flag = flagsmith.getAllFlags()['<flag>'];
if (flag?.experiment?.inExperiment) flagsmith.trackExposureEvent('<flag>', { value: flag.variant });
```

Exposures are deduplicated per identity (first variation seen wins), so recording twice is safe.

## 3. Conversion: the event the metric counts

Name must equal the metric's event, case-sensitive. Optional numeric `value` for sum/mean metrics.

```js
flagsmith.trackEvent('<event>');                                   // JS / React
flagsmith.track_event("<event>", identifier=uid)                   # Python
flagsmith.trackEvent("<event>", uid, null, null, null);            // Java (value, traits, metadata)
flagsmith.trackEvent('<event>', { identifier: uid });              // Node.js
client.TrackEvent("<event>", &flagsmith.EventOptions{Identifier: uid}) // Go
await flagsmith.trackEvent('<event>', user: user);                 // Flutter
```

## 4. Flush before the process or page goes away

Events batch every 10 s by default. Browser: `flushEvents()` on the converting click and on
`pagehide`. Node: `await flagsmith.close()`. Python: `max_buffer_items=1` for scripts. Java:
`flagsmith.close()`. Go: `client.FlushEvents(ctx)`. Flutter: `await flagsmith.flushEvents()`.

## Checklist before starting the experiment

- [ ] same identifier for flag evaluation and events
- [ ] exposure recorded where the variation is actually seen, once per render
- [ ] conversion recorded where success happens, with the exact metric event name
- [ ] flush on exit/navigation
- [ ] nothing secret committed
