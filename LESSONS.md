# Lessons

What stands now. Edit or remove an entry when it is reversed or stops holding.

## Decisions

- 2026-10-30, a saved Claude login whose refresh Anthropic refuses: its row
  reads "(<plan>, log in again)", not "(free?)", and a refresh adds no
  notice line for it ("wait, no notice. don't pollute my nice list").
- 2026-11-01, a click on an account row while usage refreshes: "Queue the
  switch"; it runs once the refresh ends.
- 2026-11-01, waiters for a provider's turn go in arrival order through a
  new public `Paths.turnQueue(_:)` and a `turn-<provider>.queue/` lock
  folder beside each turn file in the store: "Approve both".

## Lessons

- Anthropic stopped sending a 5-hour window for some Claude accounts
  (cafebabe, hi, laude, olofi, joelr1, deadbeef by 2026-11-01): their
  usage answer carries only the weekly and Fable windows, and Kiba records
  no session limit for them.
- On 2026-11-01 17:43-17:47 kiba CLI probes from waiting auto-switch
  sessions ran 13 rounds of 16 accounts back to back; Anthropic throttled
  every usage check, and the panel's own probe waited for the turn the
  whole time, so every row stayed disabled (history table, kiba.db).
