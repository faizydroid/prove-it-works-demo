# Flagsmith Experimentation API, as the scripts use it

Everything goes through `flagsmith api <path>` so the CLI's credentials apply. `-X` sets the method,
`--input -` reads a JSON body from stdin, `-f key=value` adds a string field (POST implied),
`--jq <expr>` filters the response (compact JSON for objects, raw text for strings).

`<env>` is the environment's **client-side** key. Experiments, metrics and warehouse connections are
all scoped to an environment.

| Purpose | Method and path | Notes |
|---|---|---|
| Warehouse connections | `GET api/v1/environments/<env>/warehouse-connections/` | plain list; `status`: created, pending_connection, connected, errored |
| Enable managed warehouse | `POST …/warehouse-connections/` body `{"warehouse_type":"flagsmith","name":"Flagsmith"}` | then `POST …/warehouse-connections/<id>/test-warehouse-connection/` sends the first event |
| Metrics | `GET/POST api/v1/environments/<env>/experiment-metrics/` | paginated (`results`); body `{"name","aggregation":"occurrence","direction":"up","definition":{"version":1,"event":"<event>"}}` |
| Experiments | `GET/POST api/v1/environments/<env>/experiments/` | paginated; 409 if the feature already has an unfinished experiment |
| One experiment | `GET …/experiments/<id>/` | `status`: created, running, paused, completed; `feature.multivariate_options[]` has `{id,key,value}` |
| Start / pause | `POST …/experiments/<id>/start/` · `…/pause/` | start enables the rollout and locks the flag |
| Complete + decide | `POST …/experiments/<id>/complete/` body `{"rollout_decision":"variant","rollout_variant":<option id>}` or `{"rollout_decision":"control"}` or `{"rollout_decision":"disable"}` | sets the environment default (winner at weight 100, others 0), removes the rollout override, freezes results |
| Change rollout | `PATCH …/experiments/<id>/rollout/` | same body shape as `experiment_rollout`; changing it mid-run hurts validity |
| Results | `GET …/experiments/<id>/results/` | `{"results": null \| {as_of, is_final, last_error_at, payload}}` |
| Recompute results | `POST …/experiments/<id>/results/refresh/` | 202; async; throttled to one per 5 minutes (429 says how long) |
| Exposures | `GET …/experiments/<id>/exposures/` · `POST …/exposures/refresh/` | enrolment over time, excluded identities |

## Create-experiment body

```json
{
  "feature": 12,
  "name": "Headline: human vs AI",
  "hypothesis": "The AI headline lifts CTA clicks by 20% within a week.",
  "metrics": [{ "metric": 5, "expected_direction": "increase" }],
  "experiment_rollout": {
    "enabled": true,
    "rollout_percentage": 100,
    "feature_state_value": { "type": "string", "value": "<control value>" },
    "multivariate_feature_state_values": [
      { "multivariate_feature_option": 34, "percentage_allocation": 50 }
    ]
  }
}
```

Control takes whatever the variations don't. `expected_direction`: increase, decrease, not_increase,
not_decrease. Metric `aggregation`: occurrence (converted at least once), count, sum, mean;
`direction`: up, down, informational.

## Results payload (what `results.sh` summarises)

```json
{
  "srm_p_value": 0.83,
  "metrics": [{
    "metric_id": 5,
    "variants":  { "control": {"n": 312, "sum": 25, "sum_squares": 25}, "ai": {"n": 305, "sum": 34, "sum_squares": 34} },
    "inference": { "ai": {"lift": 0.39, "ci_low": 0.05, "ci_high": 0.72, "chance_to_win": 0.97} }
  }],
  "exposures_timeseries": { "granularity": "hour", "points": [] }
}
```

- `n` identities exposed, `sum` conversions (for occurrence metrics).
- `inference[key]` is `null` while a variant has under 50 identities or under 5 conversions
  ("collecting data"). `chance_to_win` is the posterior probability the variant beats control; for
  lower-is-better metrics it is already inverted.
- `srm_p_value` is computed once 100+ identities are in. Below 0.001 the split is broken: don't trust
  the numbers.
- Verdict thresholds used by `results.sh`: winner at `chance_to_win >= 0.95` **and** `ci_low > 0`;
  control wins when every variant has `chance_to_win <= 0.05` and `ci_high < 0`.

## Flags and variants via the CLI

```
flagsmith feature create <flag> --value "<control>" --enabled          # standard flag, string value
flagsmith feature variant add <flag> --key <key> --value "<v>" --weight 0   # keyed; becomes multivariate
flagsmith feature get <flag> --json         # {id,name,type,default_value,enabled,variants:[{id,key,value,weight}]}
flagsmith flag get <flag> --json            # this environment: {enabled,value,variants:[{key,weight}],segment_overrides,…}
flagsmith flag update <flag> --weight <key>=0   # rollback after a variant rollout: control's value serves again
flagsmith feature update <flag> --archive
```

A variant without a `key` records no exposures. `control` is reserved for the flag's own value.
