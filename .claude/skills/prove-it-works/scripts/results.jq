# results.jq — turns GET .../experiments/<id>/results/ into a verdict. Used by results.sh.
# Input:  {"results": null | {"as_of","is_final","payload":{"srm_p_value","metrics":[{"metric_id","variants","inference"}]}}}
# Needs (prepended by results.sh):
#   def primary_metric_id: <id or null>;         null = first metric expected to increase/decrease
#   def expected:    {"control":0.5,"b":0.5};     the experiment's own split, for the SRM check
#   def metric_meta: [{"id","name","dir","direction"}];   from the experiment's metrics
# Thresholds mirror Flagsmith's results page: inference appears at 50+ identities and 5+ conversions
# per variant; a variant "wins" at a 95% chance to beat control; SRM below p = 0.001 voids the test.

def r3: (. * 1000 | round) / 1000;
def r4: (. * 10000 | round) / 10000;
def pct: (. * 100 | round);
# Chance to win with one decimal, never shown as a certainty: 0.995 -> 99.5, 0.9996 -> 99.9.
def chance: ((. * 1000 | round) / 10) | if . >= 100 then 99.9 elif . <= 0 then 0.1 else . end;
def signed: if . >= 0 then "+\(.)" else "\(.)" end;

# Chi-squared survival function for integer degrees of freedom; same recurrence as Flagsmith's stats.py.
def chi2_sf($stat; $df):
  if $stat <= 0 then 1
  else ($stat / 2) as $y
  | (if $df % 2 == 1 then {a: 0.5, s: ($y | sqrt | erfc)} else {a: 1, s: (0 - $y | exp)} end)
  | until(.a + 1 > $df / 2; .s += ((.a * ($y | log) - $y - (.a + 1 | lgamma)) | exp) | .a += 1)
  | .s
  end;

# SRM against the experiment's own split. Flagsmith's beta checks the flag's environment-default
# weights instead, which are 0% for variants added at weight 0, so its srm_p_value stays null.
def srm_local($v):
  (expected | to_entries | map(select(.value > 0))) as $e
  | ([$e[] | $v[.key].n // 0] | add // 0) as $total
  | if ($e | length) < 2 or $total < 100 then null
    else ([$e[] | (($v[.key].n // 0) - $total * .value) as $d | $d * $d / ($total * .value)] | add) as $stat
    | chi2_sf($stat; ($e | length) - 1)
    end;

# One metric's payload -> counts per variant, inference per treatment, and whether it's still collecting.
def summarize:
  (.variants // {}) as $v
  | (.inference // {}) as $inf
  | ($v | with_entries(.value |= { n: .n, conversions: (.sum | round),
                                    rate: (if .n > 0 then (.sum / .n | r4) else 0 end) })) as $base
  | ($inf | with_entries(select(.value != null))
          | with_entries(.value |= { lift: (.lift | r3), ci: [(.ci_low | r3), (.ci_high | r3)],
                                     chance_to_win: (.chance_to_win | r3) })) as $stats
  | { base: $base, stats: $stats,
      collecting: ($inf | length == 0 or (to_entries | any(.value == null))),
      variants: ($base | with_entries(.value += ($stats[.key] // {}))) };

# A guardrail is "harmed" when a treatment clearly moved it the wrong way (95% sure, interval clear of 0).
def guardrail($meta):
  summarize as $s
  | ($s.stats | to_entries | map(
      .value as $x
      | (if $meta.direction == "down" then 1 - $x.chance_to_win else $x.chance_to_win end) as $p_up
      | select(($meta.dir == "not_decrease" and $p_up <= 0.05 and $x.ci[1] < 0)
            or ($meta.dir == "not_increase" and $p_up >= 0.95 and $x.ci[0] > 0))
      | .key)) as $harmed_by
  | { name: $meta.name, expected: $meta.dir,
      status: (if ($harmed_by | length) > 0 then "harmed" elif $s.collecting then "collecting" else "ok" end),
      harmed_by: $harmed_by,
      variants: ($s.variants | with_entries(.value |= {rate} + (if .lift != null then {lift, ci} else {} end))) };

.results as $r
| if $r == null or $r.payload == null then
    { as_of: ($r.as_of // null), is_final: ($r.is_final // false),
      srm_p_value: null, srm_warning: false, variants: {}, guardrails: [],
      verdict: "no_results", winner: null,
      reason: "No results computed yet. Run with --refresh (allowed every 5 minutes)." }
  else
    ($r.payload.metrics // []) as $ms
    | (primary_metric_id
       // ([metric_meta[] | select(.dir == "increase" or .dir == "decrease") | .id][0])
       // ($ms[0].metric_id // null)) as $pid
    | ($ms | map(select(.metric_id == $pid)) | .[0] // $ms[0] // {}) as $m
    | ($m | summarize) as $s
    | $s.variants as $variants
    | (if $r.payload.srm_p_value != null then "flagsmith" else "local" end) as $srm_source
    | (($r.payload.srm_p_value // srm_local($s.base)) | if . == null then null else r4 end) as $srm
    | ($srm != null and $srm < 0.001) as $srm_bad
    | ($s.stats | to_entries | sort_by(-.value.chance_to_win) | .[0]) as $best
    | [ $ms[] | select(.metric_id != $m.metric_id) | . as $gm
        | (metric_meta | map(select(.id == $gm.metric_id)) | .[0]
           // {name: "metric \($gm.metric_id)", dir: "not_decrease", direction: "up"}) as $meta
        | $gm | guardrail($meta) ] as $guards
    | ($guards | map(select(.status == "harmed"))) as $harmed
    | ( if $srm_bad then "srm"
        elif $s.collecting then "collecting"
        elif $best.value.chance_to_win >= 0.95 and $best.value.ci[0] > 0 then
          (if ($harmed | map(select(.harmed_by | index($best.key))) | length) > 0 then "guardrail" else "winner" end)
        elif ($s.stats | to_entries | all(.value.chance_to_win <= 0.05 and .value.ci[1] < 0)) then "control_wins"
        else "inconclusive" end ) as $verdict
    | { as_of: $r.as_of, is_final: $r.is_final, srm_p_value: $srm,
        srm_source: (if $srm == null then null else $srm_source end), srm_warning: $srm_bad,
        variants: $variants, guardrails: $guards, verdict: $verdict,
        winner: (if $verdict == "winner" then $best.key elif $verdict == "control_wins" then "control" else null end),
        candidate: ($best.key // null),
        reason: (
          if $verdict == "srm" then
            "Sample ratio mismatch (p=\($srm)): traffic did not split as configured. Do not act on these numbers."
          elif $verdict == "collecting" then
            "Collecting data: every variant needs 50+ identities and 5+ conversions. So far: \($variants | to_entries | map("\(.key) \(.value.n) seen/\(.value.conversions) converted") | join(", "))."
          else
            "\($best.key): \($best.value.chance_to_win | chance)% chance to beat control (\($best.value.lift | pct | signed)% lift, 95% CI \($best.value.ci[0] | pct | signed)%..\($best.value.ci[1] | pct | signed)%)"
            + (if $verdict == "guardrail" then ", but it hurt guardrail(s): \($harmed | map(.name) | join(", ")). Don't ship without the human's explicit override." else "" end)
          end ) }
  end
