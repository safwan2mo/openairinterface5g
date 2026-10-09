#!/bin/bash
# SPDX-License-Identifier: LicenseRef-CSSL-1.0
#
# Build all images and run the rfsim Xn handover CI test locally, unattended
# (detaches into the background). Progress and per-step results are in
# $LOG_DIR/STATUS, per-step output in $LOG_DIR/<step>.log, the CI report and
# logs are copied to $LOG_DIR/results at the end.
#
# Usage: run_xn_ho_ci.sh [--no-build]
#   --no-build  reuse existing oai-gnb/oai-nr-cuup/oai-nr-ue images
# Environment:
#   LOG_DIR     log directory (default: ~/xn-ho-ci/<date>-<time>)

SCENARIO_DIR=$(dirname "$(realpath "$0")")
REPO=$(realpath "$SCENARIO_DIR/../../..")
CI_DIR=$REPO/ci-scripts
OPEN5GS_IMG=oaisoftwarealliance/open5gs:v2.7.6
XML=xml_files/container_5g_rfsim_xn_ho.xml

BUILD=1
for arg in "$@"; do
  case $arg in
    --no-build) BUILD=0 ;;
    *) echo "usage: $0 [--no-build]"; exit 2 ;;
  esac
done

if [ -z "$XN_HO_CI_DETACHED" ]; then
  export LOG_DIR=${LOG_DIR:-$HOME/xn-ho-ci/$(date +%Y%m%d-%H%M%S)}
  mkdir -p "$LOG_DIR" || exit 1
  XN_HO_CI_DETACHED=1 setsid nohup "$0" "$@" > "$LOG_DIR/run.log" 2>&1 < /dev/null &
  echo "started in background (pid $!), logs in $LOG_DIR"
  echo "  status:   cat $LOG_DIR/STATUS"
  echo "  progress: tail -f $LOG_DIR/run.log"
  exit 0
fi

STATUS=$LOG_DIR/STATUS
n=0
status() { echo "$(date '+%F %T') $*" | tee -a "$STATUS"; }

# run a step, its output going to $LOG_DIR/<NN>-<name>.log; abort the run if it fails
step() {
  local name=$1; shift
  n=$((n + 1))
  local log
  log=$(printf "%s/%02d-%s.log" "$LOG_DIR" "$n" "$name")
  local start=$SECONDS
  status "RUN  $name"
  if "$@" > "$log" 2>&1; then
    status "OK   $name ($((SECONDS - start))s)"
  else
    status "FAIL $name ($((SECONDS - start))s), see $log"
    finish 1
  fi
}

finish() {
  mkdir -p "$LOG_DIR/results"
  cp "$CI_DIR/test_results.html" "$LOG_DIR/results/" 2>/dev/null
  cp -r "$REPO/cmake_targets/log/$(basename $XML).d" "$LOG_DIR/results/" 2>/dev/null
  (cd "$SCENARIO_DIR" && docker compose down -v --remove-orphans) >> "$LOG_DIR/cleanup.log" 2>&1
  if [ "$1" -eq 0 ]; then status "RESULT: PASS"; else status "RESULT: FAIL"; fi
  exit "$1"
}

check_prerequisites() {
  local missing=0
  for c in docker git jq column ncat python3; do
    command -v $c > /dev/null || { echo "missing command: $c"; missing=1; }
  done
  docker compose version || { echo "missing docker compose plugin"; missing=1; }
  docker info > /dev/null || { echo "docker not usable by $(id -un) (daemon down, or user not in docker group?)"; missing=1; }
  for m in lxml paramiko yaml; do
    python3 -c "import $m" || { echo "missing python module: $m"; missing=1; }
  done
  # NGAP, F1, E1 and XnAP run over SCTP inside the containers
  [ -e /proc/net/sctp ] || { echo "SCTP not available in the kernel (sudo modprobe sctp)"; missing=1; }
  return $missing
}

build_ran() {
  cd "$REPO" || return 1
  docker build . -f docker/Dockerfile.base.ubuntu -t ran-base &&
  docker build . -f docker/Dockerfile.build.ubuntu -t ran-build &&
  docker build . -f docker/Dockerfile.gNB.ubuntu -t oai-gnb &&
  docker build . -f docker/Dockerfile.nr-cuup.ubuntu -t oai-nr-cuup &&
  docker build . -f docker/Dockerfile.nrUE.ubuntu -t oai-nr-ue
}

check_ran_images() {
  docker image inspect oai-gnb oai-nr-cuup oai-nr-ue > /dev/null
}

# image name used by docker-compose.yaml; present locally, compose does not try to pull it
build_open5gs() {
  docker build -t $OPEN5GS_IMG "$SCENARIO_DIR/open5gs"
}

pull_third_party() {
  docker pull mongo:6.0 && docker pull oaisoftwarealliance/trf-gen-cn5g:latest
}

clean_previous() {
  cd "$SCENARIO_DIR" && docker compose down -v --remove-orphans
}

run_test() {
  cd "$CI_DIR" && ./run_locally.sh $XML
}

status "repo $REPO, branch $(git -C "$REPO" rev-parse --abbrev-ref HEAD) @ $(git -C "$REPO" rev-parse --short HEAD)"
step prerequisites check_prerequisites
if [ $BUILD -eq 1 ]; then
  step build-ran-images build_ran
else
  step check-ran-images check_ran_images
fi
step build-open5gs-image build_open5gs
step pull-third-party-images pull_third_party
step clean-previous-deployment clean_previous
step run-ci-test run_test
finish 0
