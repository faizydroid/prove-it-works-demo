# Exposures or conversions not showing up

Work down the list; the SDKs skip bad events silently instead of throwing.

1. **Warehouse.** `preflight.sh` must show `connected` or `pending_connection`. The ingestion service
   rejects events for environments without a connection.
2. **Identity.** Events without an identified user are dropped. Identify before the experiment-flag
   call, and use the same identifier for flags and events.
3. **Variant keys.** Every variation needs a `key`; exposures are attributed by key.
   `flagsmith feature variant list <flag>` shows them.
4. **Experiment running.** `results.sh --id <id>` reports `status`. Identities outside the rollout
   percentage are not enrolled and record nothing.
5. **Flushed.** Browser: `flushEvents()` on click/pagehide. Scripts and servers: flush/close before
   exit. Batches go out every 10 s by default.
6. **Event name.** Case-sensitive, must equal the metric's `definition.event`. Unmatched events are
   ignored, not errored. `GET api/v1/environments/<env>/warehouse-connections/<id>/events/` lists the
   distinct event names the warehouse has actually received.
7. **Timestamps.** Events older than 10 days or more than 24 h in the future are rejected; a batch
   over 2 MiB is rejected whole.
8. **Only after exposure.** Conversions count only after an identity's first exposure. A click
   recorded before the headline rendered doesn't count.
9. **Results lag.** Events take a minute to land; results recompute only on `--refresh`
   (every 5 minutes). Don't poll faster, the API throttles.
10. **Excluded identities.** The Exposures panel quarantines identities that saw more than one
    variation. A few is normal; a growing count means identities are changing between visits
    (e.g. a new random id every page load).

Turn on SDK debug logging (`enableLogs: true` in the JS SDK) to see why an event was skipped.
