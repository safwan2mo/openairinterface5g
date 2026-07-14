# NR UE Measurement Reporting: Diagnosis and Periodic Reporting Implementation

Investigation into why the UE was not sending any `MeasurementReport` for a `measConfig`
containing periodical + eventA2 + eventA3 report configs, followed by implementation of
standalone periodical reporting (previously entirely unimplemented).

---

## Starting point

Test `RRCReconfiguration` (xer) contained:

```
measIdToAddModList:
  measId 1 -> measObjectId 1 (PCI 0, ssbFrequency 641280) -> reportConfigId 1 (periodical, ms1024, infinity)
  measId 2 -> measObjectId 2 (PCI 1, ssbFrequency 621312) -> reportConfigId 1 (periodical, ms1024, infinity)
  measId 3 -> measObjectId 1                              -> reportConfigId 2 (eventA2, threshold=60, hyst=0, ttt=40ms)
  measId 4 -> measObjectId 2                              -> reportConfigId 4 (eventA3, offset=10, hyst=0, ttt=40ms)
measGapConfig: gapUE (gapOffset 0, mgl ms6, mgrp ms160, mgta ms0dot5)
```

No `MeasurementReport` was ever observed at the gNB.

## Diagnostic logging added

- `openair2/RRC/NR_UE/rrc_UE.c` — `nr_rrc_ue_process_rrcReconfiguration()` now unconditionally
  logs + `xer_fprint`s every received `RRCReconfiguration`.
- `openair2/RRC/NR/rrc_gNB.c` — `rrc_gNB_process_MeasurementReport()` now unconditionally logs +
  `xer_fprint`s every received `MeasurementReport` (previously gated behind `LOG_DEBUGFLAG(DEBUG_ASN1)`).

## Root cause: `periodical` reportType was entirely unimplemented

`nr_ue_check_meas_report()` (`rrc_UE.c:3033`, called from `nr_rrc_handle_meas_indication()` on
every PHY measurement indication) explicitly skipped any reportConfig that wasn't
`eventTriggered`:

```c
if (report_config_nr->reportType.present != NR_ReportConfigNR__reportType_PR_eventTriggered)
  continue;
```

So measId 1 and measId 2 (both `periodical`) could never produce a report, regardless of RSRP.
The `periodic_report_timer` field in `l3_measurements_t` existed but was only ever armed as a
*follow-up* to an A2/A3 event firing, never standalone.

measId 3 (A2) / measId 4 (A3) were evaluated, but conditioned on real threshold crossings:
- A2 threshold `60` -> ` -97 dBm` (`rrc_UE.c:2937`, `threshold - 157`) — requires a very weak
  serving cell, unlikely on a healthy rfsim link.
- A3 offset `10` -> `5 dB` (`rrc_UE.c:2980`, `offset >> 1`) — requires a *valid* neighbor RSRP
  sample 5 dB above serving.

### Additional blocker for measId 4 specifically

measObject 1 (serving, PCI 0) and measObject 2 (PCI 1) are on **different SSB frequencies**
(641280 vs 621312) — i.e. inter-frequency. But `check_meas_to_perform()` /
`search_neighboring_cell()` only ever measures a neighbor PCI on the **same** frequency as the
serving cell, reusing the already-captured rxdata buffer with no retuning:

```c
// openair1/SCHED_NR_UE/phy_procedures_nr_ue.c:811
nr_neighboring_cell->ssb_freq == 0 || ssb_freq == serving_ssb_freq
```

So PCI 1 is never actually searched for, `neighboring_cell[]` RSRP stays `INT_MAX`, and A3 can
never fire for measId 4 independent of the periodical/gap gaps below.

### Measurement gaps: parsed but inert

`measGapConfig` is stored on `rrcNB->measGapConfig` and freed on release
(`rrc_UE.c:2585`) but never otherwise read. `nr_rrc_ue_process_measConfig()` logs
`"Measurement gaps not yet supported!"` (`rrc_UE.c:1517`) and does nothing else with it. There is
no SMTC parsing, no MAC "reserved slot" concept, and RF retuning
(`nrue_ru_set_freq()`, `executables/nr-ue-ru.c:373`) is a one-shot permanent switch used only for
cell (re)selection — not a tune-away-and-return gap cycle. Implementing gaps properly requires
changes across RRC (parse `MeasGapConfig`/SMTC), MAC (reserved-slot scheduling), and PHY/RF
(retune-and-return, or a second RF chain) — estimated at multiple weeks of work, materially
larger than periodic reporting.

## What was implemented: standalone periodical reporting

Design goal: support multiple *concurrent* periodical measIds (the test config has two:
measId 1 and measId 2), without touching the existing A2/A3 event-trigger state machine, which
is itself single-slot per gNB (`l3_measurements_t` has one shared `trigger_to_measid` /
`reports_sent` / timer set, so only one event-triggered report session can be in flight at a
time — a pre-existing limitation, left as is).

- **`openair2/RRC/NR_UE/rrc_defs.h`** — new `nr_periodic_meas_report_t` (active flag, rsType,
  reports_sent, max_reports, report_interval_ms, own `NR_timer_t`), stored as
  `periodic_reports[MAX_MEAS_ID]` in `rrcPerNB_t`, indexed directly by measId (same convention as
  `MeasId[]`/`MeasReport[]`).
- **`handle_measid_addmod()`** (`rrc_UE.c`) — new sibling branch for
  `NR_ReportConfigNR__reportType_PR_periodical`: reads `rsType`/`reportInterval`/`reportAmount`
  from `NR_PeriodicalReportConfig_t` and starts the measId's own timer immediately at
  configuration time (periodical reporting isn't conditioned on any RSRP threshold).
- **`handle_meas_reporting_remove()`** (`rrc_UE.c`) — now also stops/clears
  `periodic_reports[id]`, so removal/reconfiguration of a measId or its reportConfig cleans up
  the periodic timer along with the existing event-trigger cleanup.
- **`rrc_ue_generate_periodic_measurementReport()`** (new, `rrc_UE.c` + `rrc_proto.h`) — thin
  sibling of `rrc_ue_generate_measurementReport()` that takes `measId`/`rsType` as explicit
  parameters instead of reading the shared event-trigger fields, so it can be called
  independently per measId. Still delegates encoding to `do_nrMeasurementReport_SA()`.
- **`handle_meas_timers()`** (`rrc_timers_and_constants.c`) — new loop over
  `nb->periodic_reports[MAX_MEAS_ID]` alongside the existing A2/A3 timer handling; ticks each
  active periodic timer, sends a report and increments `reports_sent` on expiry, re-arms up to
  `max_reports`, then deactivates.

### Known limitations of this implementation

- **RSRP only** — `do_nrMeasurementReport_SA()` only ever encodes an RSRP quantity result;
  RSRQ/SINR requested via `reportQuantityCell`/`reportQuantityRS-Indexes` are not encoded. This
  matches the pre-existing event-triggered path's limitation; not addressed here.
- **At most one neighbor cell per report** — `neighboring_cell[0]` is hardcoded in the encoder,
  not a loop over all qualifying cells up to `maxReportCells`. Also pre-existing, not addressed.
  Periodical reporting for measId 2 (PCI 1, inter-frequency) will therefore still report the
  serving cell only, with `neighbor_cell_valid == false`, until the frequency-match guard and
  measurement gaps are addressed (see above) — that gap remains open regardless of this change.
  measId 1 (PCI 0, same frequency as serving) is unaffected and reports normally.
  - **`quantityConfigIndex`** (per-measObject filter selection) is ignored; a single filter
  coefficient set is applied globally, matching existing behavior elsewhere in this file.

## gNB-side pretty print (replaces full xer dump)

Once periodic reports were confirmed flowing, the earlier unconditional `xer_fprint` dump of the
full `MeasurementReport` in `rrc_gNB_process_MeasurementReport()` (`rrc_gNB.c`) was replaced with
a new `log_measurement_report()` helper that prints a one-line summary — measId, serving PCI +
RSRP, and each neighbor PCI + RSRP — via `LOG_UE_UL_EVENT()`, matching the terse
`"UE <rnti>: ..."` style already used by `dump_mac_stats()` in
`openair2/LAYER2/NR_MAC_gNB/main.c` for the per-UE PHY/MAC stats log, instead of a raw ASN.1 XML
dump. Applies to every received `MeasurementReport` (periodical and event-triggered alike),
called once up front in `rrc_gNB_process_MeasurementReport()` before dispatching to
`process_Periodical_Measurement_Report()` / `process_Event_Based_Measurement_Report()`.
