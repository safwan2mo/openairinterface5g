<!-- SPDX-License-Identifier: LicenseRef-CSSL-1.0 -->

# rfsim Xn handover CI pipeline

Deployment + scenario for **inter-gNB Xn handover** in the rfsimulator, the Xn-interface
counterpart of the existing F1 and N2 handover pipelines:

| Handover type | Scenario XML | Deployment | Trigger (telnet `ci` shell) |
|---|---|---|---|
| F1 (intra-CU, DU↔DU) | `xml_files/container_5g_f1_rfsim.xml` | `yaml_files/5g_f1_rfsimulator/` | `ci trigger_f1_ho` |
| N2 (inter-CU, AMF-anchored) | `xml_files/container_5g_rfsim_n2_ho.xml` | `yaml_files/5g_rfsimulator_n2_ho/` | `ci trigger_n2_ho <pci>,<ueId>` |
| **Xn (inter-gNB, Xn-anchored)** | **`xml_files/container_5g_rfsim_xn_ho.xml`** | **this directory** | **`ci trigger_xn_ho <target_pci>,<ueId>`** |

## Status: pending runtime support

OAI currently ships only the **XnAP ASN.1 codec** (`openair2/XNAP/lib`) and its unit tests
(`openair2/XNAP/tests/xnap_lib_test.c`). There is **no XnAP SCTP task**, no Xn interface
bring-up in the gNB, and no RRC hook that sources/targets an Xn handover.

What is already in place for this pipeline:

* `common/utils/telnetsrv/telnetsrv_ci.c` — `ci trigger_xn_ho <target_pci>,<ueId>` command
  (wired, argument-validated, currently returns *"not implemented"*; a `TODO(xn-ho)`
  marks where to call the future `nr_HO_Xn_trigger_telnet()`).
* `ci-scripts/conf_files/gnb-cucp.sa.e1-ho-xn.conf` — CU-CP config with a proposed
  `Xn_INTERFACE` block (parsed-but-inert until the XnAP task exists).
* `docker-compose.yaml` (this dir) — 5GC + two gNBs (`0xe00`/PCI 0 and `0xb00`/PCI 1)
  peered over Xn on port 38422, plus one rfsim NR-UE.
* `ci-scripts/xml_files/container_5g_rfsim_xn_ho.xml` — the scenario (see below).

Until the runtime path lands, the scenario is **expected to fail at the first
`Trigger Xn Handover` step**. Do **not** add it to the `RAN-RF-Sim-Test-5G` Jenkins job
list yet.

## Topology

```
                 OAI 5GC (mysql/amf/smf/upf/ext-dn)
                  |                              |
               NG |                              | NG
        +--------------------+   Xn 38422   +--------------------+
        | gNB-0  ID 0xe00    |<------------>| gNB-1  ID 0xb00    |
        |  PCI 0             |              |  PCI 1             |
        |  cucp-0  .150 :9090|              |  cucp-1  .180 :9090|
        |  cuup-0  .151     |               |  cuup-1  .181     |
        |  du-0    .171 :9090|              |  du-1    .182     |
        +--------------------+              +--------------------+
                    \                        /
                     \      rfsim RF        /
                      +--- oai-nr-ue .190 --+
```

## Scenario flow (`container_5g_rfsim_xn_ho.xml`)

1. Deploy 5GC, then gNB-0 + UE; attach; baseline ping both directions.
2. Deploy gNB-1; wait for the Xn association; trace `Xn Setup`.
3. **5 "ping-pong" handovers**, round-robin between the two gNBs:
   `0→1 → 1→0 → 0→1 → 1→0 → 0→1`.
   For every hop:
   * trigger via `ci trigger_xn_ho <target_pci>,1`
   * trace each protocol step from the container logs — XnAP `HANDOVER REQUEST`,
     `HANDOVER REQUEST ACKNOWLEDGE`, RRC `RRCReconfiguration` (HO Command),
     XnAP `HANDOVER SUCCESS`, NGAP `PATH SWITCH REQUEST`
   * ping both directions (bearer must survive)
   * `ci fetch_du_by_ue_id` on the **target** CU-CP to prove the UE moved
     (`gNB_DU_ID 1234` for gNB-1, `3584` = `0xe00` for gNB-0)
4. `iperf` DL after hop 2, UL after hop 4, DL after hop 5.
5. Undeploy with `LogAnalysis`: every gNB component must `EndsWithBye` (no crash /
   no ASan abort), DUs pass `RetxCheck`.

Acceptance-criteria mapping:

| Criterion | Where |
|---|---|
| 5 ping-pong HO without crash in RFsim | 5 trigger steps + ASan images + `EndsWithBye` analysis |
| Round-robin between N gNBs | N=2, alternating `0↔1` sequence |
| UE migrates source→target | `fetch_du_by_ue_id` after every hop |
| Logs trace each message step | `Trace: …` `Custom_Command` steps per hop |
| Validation of functionality | ping both directions + iperf DL/UL survive every hop |

## Running locally

```bash
# build oai-gnb / oai-nr-cuup / oai-nr-ue images first (see ci-scripts/README.md)
cd ci-scripts/
./run_locally.sh xml_files/container_5g_rfsim_xn_ho.xml
```

Results in `ci-scripts/test_results.html`, per-run logs under
`cmake_targets/log/container_5g_rfsim_xn_ho.xml.d/`.

## Enabling once Xn HO works

1. Replace the `ERROR_MSG_RET(...)` in `rrc_gNB_trigger_xn_ho()`
   (`common/utils/telnetsrv/telnetsrv_ci.c`) with the real RRC trigger call and make it
   print `RRC Xn handover triggered for UE <id> toward target PCI <pci>` (the scenario
   greps for that string).
2. Set `xnap_log_level = "debug"` in `gnb-cucp.sa.e1-ho-xn.conf` and align the
   `grep -E` patterns in the `Trace: …` steps with the strings the XnAP task logs.
3. Confirm `Xn_INTERFACE` matches the config schema the XnAP task actually reads
   (adjust the `--gNBs.[0].Xn_INTERFACE.[0].*` overrides in `docker-compose.yaml`).
4. Add `container_5g_rfsim_xn_ho.xml` to the `RAN-RF-Sim-Test-5G` job's scenario list.
