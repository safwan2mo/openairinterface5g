# rfsim Xn handover (2 gNBs, Open5GS 5GC)

CI scenario: `ci-scripts/xml_files/container_5g_rfsim_xn_ho.xml`

Two gNBs (each CU-CP + CU-UP + DU) peered over Xn, one rfsim NR-UE, and an
Open5GS 5GC. The UE is handed over 5 times (ping-pong) with
`ci trigger_xn_ho <target PCI>,<UE id>`; after each hop,
`check_xn_ho.sh` checks every step in the CU-CP logs, then the UE has to be on
the target DU, and ping/iperf have to pass.

The OAI 5GC does not support NGAP Path Switch Request, which completes an Xn
handover at the target gNB, so this scenario uses Open5GS instead.

| Node            | Address         | Notes                                 |
|-----------------|-----------------|---------------------------------------|
| mongo           | 192.168.71.131  | subscriber DB, `open5gs/subscriber.js` |
| open5gs         | 192.168.71.132  | all NFs; NGAP + N3 here, SBI on loopback; 192.168.72.134 towards ext-dn |
| oai-ext-dn      | 192.168.72.135  | ping/iperf server                     |
| gNB-0 CU-CP     | 192.168.71.150  | gNB_ID 0xe00, PCI 0, telnet :9090     |
| gNB-0 CU-UP/DU  | .151 / .171     | gNB_DU_ID 3584                        |
| gNB-1 CU-CP     | 192.168.71.180  | gNB_ID 0xb00, PCI 1, telnet :9090     |
| gNB-1 CU-UP/DU  | .181 / .182     | gNB_DU_ID 1234                        |
| oai-nr-ue       | 192.168.71.190  | rfsim server, IMSI 208990100001100    |

PLMN 208/99, TAC 1, SST 1, DNN `oai`, UE pool 12.1.1.0/24: the same values as
the OAI 5GC scenarios, so the gNB/UE configuration files are shared with them.

## Open5GS image

`open5gs/Dockerfile` builds all Open5GS NFs (v2.7.6, from source) into one
image. The `open5gs` service runs all of them in one container
(`open5gs/start.sh`, configs from `open5gs/config/`); the container stops as
soon as one NF exits.

docker-compose.yaml uses it as `oaisoftwarealliance/open5gs:v2.7.6`, which
`docker compose up` pulls when it is not present locally, like the 5GC images
of the other scenarios. Build it on machines where it is not published (once
per Open5GS version):

```bash
docker build -t oaisoftwarealliance/open5gs:v2.7.6 ci-scripts/yaml_files/5g_rfsimulator_xn_ho/open5gs
```

`run_xn_ho_ci.sh` does this before running the test.

## Run locally

Build the RAN images (`oai-gnb`, `oai-nr-cuup`, `oai-nr-ue`, see
`doc/TESTBenches.md`), then:

```bash
cd ci-scripts && ./run_locally.sh xml_files/container_5g_rfsim_xn_ho.xml
```

or by hand:

```bash
cd ci-scripts/yaml_files/5g_rfsimulator_xn_ho
docker compose up -d --wait mongo open5gs oai-ext-dn
docker compose up -d --wait oai-cucp-0 oai-cuup-0 oai-du-0 oai-nr-ue
docker compose up -d --wait oai-cucp-1 oai-cuup-1 oai-du-1
echo ci trigger_xn_ho 1,1 | ncat 192.168.71.150 9090   # gNB-0 -> gNB-1
./check_xn_ho.sh rfsim5g-oai-cucp-0 rfsim5g-oai-cucp-1 1
docker compose down -v
```
