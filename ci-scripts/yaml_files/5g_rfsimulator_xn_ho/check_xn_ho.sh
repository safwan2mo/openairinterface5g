#!/bin/bash
# SPDX-License-Identifier: LicenseRef-CSSL-1.0
#
# Check that the n-th Xn handover from <source> to <target> went through every
# step, by waiting for the n-th occurrence of each step's log line in the CU-CP
# container logs.
#
# Usage: check_xn_ho.sh <source CU-CP container> <target CU-CP container> <n>

if [ $# -ne 3 ]; then
  echo "usage: $0 <source CU-CP container> <target CU-CP container> <n>"
  exit 2
fi
src=$1
tgt=$2
n=$3

step() {
  local container=$1 desc=$2 pattern=$3 count=0
  for _ in $(seq 1 20); do
    count=$(docker logs "$container" 2>&1 | grep -cE "$pattern")
    if [ "$count" -ge "$n" ]; then
      echo "OK   $container: $desc"
      return
    fi
    sleep 1
  done
  echo "FAIL $container: $desc (seen $count times, expected >= $n)"
  exit 1
}

step "$src" "XnAP Handover Request sent"                 "Sending HandoverRequest to peer"
step "$tgt" "XnAP Handover Request received"             "Received HandoverRequest from"
step "$tgt" "XnAP Handover Request Acknowledge sent"     "Sending HandoverRequestAck to source"
step "$src" "XnAP Handover Request Acknowledge received" "Received HandoverRequestAck from"
step "$src" "RRCReconfiguration (HO command) sent"       "Xn HO: sent RRCReconfiguration"
step "$src" "XnAP SN Status Transfer sent"               "Sending SN Status Transfer to peer"
step "$tgt" "XnAP SN Status Transfer received"           "Received SN Status Transfer from"
step "$tgt" "RRCReconfigurationComplete received"        "handover for UE [0-9]+/RNTI [0-9a-f]+ complete"
step "$tgt" "NGAP Path Switch Request sent"              "sending NGAP Path Switch Request"
step "$tgt" "NGAP Path Switch Request Ack received"      "received NGAP Path Switch Request Acknowledgement"
step "$tgt" "XnAP UE Context Release sent"               "Sending UE Context Release to source"
step "$src" "XnAP UE Context Release received"           "XNAP UE Context Release received from target"
