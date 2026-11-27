#!/usr/bin/env node
// simulate-traffic.mjs — scripted identities through a running experiment, for smoke tests and
// demos. The conversion rates are inputs, printed back in the output: nobody can mistake this
// for real traffic. Never point it at a production environment.
//
//   npm install --prefix scripts            # once: installs @flagsmith/flagsmith next to this file
//   node scripts/simulate-traffic.mjs --env <client-side key> --flag landing_headline \
//        --event cta_click --users 400 --rates control=0.08,ai=0.11 [--seed 1] \
//        [--guardrail-event example_viewed --guardrail-rates control=0.6,ai=0.6] \
//        [--api https://flagsmith.example.com/api/v1/] [--events-url https://flagsmith.example.com/api/]
//
// Output (one line):
//   {"ok":true,"users":400,"in_experiment":400,"outside":0,"exposed":{"control":203,"ai":197},
//    "converted":{"control":16,"ai":23},"rates_used":{"control":0.08,"ai":0.11},"seed":1,
//    "identity_prefix":"sim-1-","note":"Results refresh is allowed every 5 minutes; events can take a minute to land."}
import { createRequire } from 'node:module';

const args = Object.fromEntries(
  process.argv.slice(2).reduce((acc, a, i, all) => {
    if (a.startsWith('--')) acc.push([a.slice(2), all[i + 1] && !all[i + 1].startsWith('--') ? all[i + 1] : 'true']);
    return acc;
  }, []),
);
const out = (o) => console.log(JSON.stringify(o));
const die = (error, hint) => { out({ ok: false, error, ...(hint ? { hint } : {}) }); process.exit(1); };

const env = args.env;
const flagName = args.flag;
const event = args.event;
const users = Number(args.users ?? 300);
const seed = Number(args.seed ?? 1);
if (!env || !flagName || !event) die('Required: --env <client-side key> --flag <name> --event <event>');
if (!Number.isInteger(users) || users < 1 || users > 20000) die('--users must be an integer between 1 and 20000');
const parseRates = (spec, flagName) => Object.fromEntries(
  String(spec).split(',').map((kv) => {
    const [k, v] = kv.split('=');
    const r = Number(v);
    if (!k || !(r >= 0 && r <= 1)) die(`Bad ${flagName} entry "${kv}": want key=probability, e.g. control=0.08,ai=0.11`);
    return [k.trim(), r];
  }),
);
const rates = parseRates(args.rates ?? 'control=0.1,variant=0.1', '--rates');
const guardEvent = args['guardrail-event'];
const guardRates = guardEvent ? parseRates(args['guardrail-rates'] ?? '', '--guardrail-rates') : null;
if (guardEvent && guardEvent === event) die('--guardrail-event must differ from --event');

let flagsmithMod;
try {
  flagsmithMod = createRequire(import.meta.url)('@flagsmith/flagsmith/isomorphic');
} catch {
  die('@flagsmith/flagsmith is not installed next to this script.', 'Run: npm install --prefix <skill>/scripts');
}
const flagsmith = (flagsmithMod.createFlagsmithInstance ?? flagsmithMod.default.createFlagsmithInstance)();

// Deterministic RNG so a demo run is reproducible: same seed, same users, same conversions.
let s = (seed >>> 0) || 1;
const rand = () => { s = (s + 0x6d2b79f5) >>> 0; let t = s; t = Math.imul(t ^ (t >>> 15), t | 1); t ^= t + Math.imul(t ^ (t >>> 7), t | 61); return ((t ^ (t >>> 14)) >>> 0) / 4294967296; };

const prefix = `sim-${seed}-`;
const exposed = {}; const converted = {}; const guarded = {};
let inExperiment = 0; let outside = 0;

const initOptions = {
  environmentID: env,
  enableEvents: true,
  cacheFlags: false,
  identity: `${prefix}0`,
};
if (args.api) initOptions.api = args.api;
if (args['events-url']) initOptions.eventProcessorConfig = { eventsApiUrl: args['events-url'] };

try {
  await flagsmith.init(initOptions);
} catch (e) {
  die(`Flagsmith init failed: ${e?.message ?? e}`, 'Check the client-side key and, when self-hosting, --api and --events-url');
}

for (let i = 0; i < users; i++) {
  const identity = `${prefix}${i}`;
  try {
    await flagsmith.identify(identity);
  } catch (e) {
    die(`identify(${identity}) failed: ${e?.message ?? e}`);
  }
  // Records the exposure for this identity in the variant Flagsmith bucketed it into.
  const flag = flagsmith.getExperimentFlag(flagName);
  if (!flag?.experiment?.inExperiment) { outside++; continue; }
  inExperiment++;
  const variant = flag.variant || 'control';
  exposed[variant] = (exposed[variant] ?? 0) + 1;
  const p = rates[variant];
  if (p === undefined) die(`No rate given for variant "${variant}". Add ${variant}=<p> to --rates`);
  if (rand() < p) {
    flagsmith.trackEvent(event);
    converted[variant] = (converted[variant] ?? 0) + 1;
  }
  if (guardEvent) {
    const g = guardRates[variant];
    if (g === undefined) die(`No guardrail rate given for variant "${variant}". Add ${variant}=<p> to --guardrail-rates`);
    if (rand() < g) {
      flagsmith.trackEvent(guardEvent);
      guarded[variant] = (guarded[variant] ?? 0) + 1;
    }
  }
  if (i % 50 === 49) await flagsmith.flushEvents();
}

await flagsmith.flushEvents();
await flagsmith.close(10000);

if (inExperiment === 0) {
  die(`None of ${users} identities entered the experiment on "${flagName}".`,
    'Is the experiment running (start-experiment.sh)? Is the rollout above 0%? Is this the right environment key?');
}
out({
  ok: true, users, in_experiment: inExperiment, outside, exposed, converted, rates_used: rates,
  ...(guardEvent ? { guardrail: { event: guardEvent, fired: guarded, rates_used: guardRates } } : {}),
  seed, identity_prefix: prefix,
  note: 'Events can take a minute to land; results.sh --refresh is allowed every 5 minutes.',
});
