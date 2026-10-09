# SPDX-License-Identifier: LicenseRef-CSSL-1.0
#
# Open5GS 5GC image for the rfsim Xn handover pipeline: one image, all NFs
# (open5gs-{nrf,ausf,udm,udr,pcf,bsf,nssf,amf,smf,upf}d), run together by
# start.sh (mounted from docker-compose.yaml).
#
# Open5GS is used instead of the OAI 5GC because it supports NGAP Path Switch,
# required to complete an Xn handover.
#
#   docker build -t oaisoftwarealliance/open5gs:v2.7.6 ci-scripts/yaml_files/5g_rfsimulator_xn_ho/open5gs

FROM ubuntu:jammy AS open5gs-build
ARG OPEN5GS_VERSION=v2.7.6
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential ca-certificates cmake bison flex git meson ninja-build pkg-config \
      python3-pip python3-setuptools python3-wheel \
      libbson-dev libcurl4-gnutls-dev libgcrypt-dev libgnutls28-dev libidn11-dev \
      libmicrohttpd-dev libmongoc-dev libnghttp2-dev libsctp-dev libssl-dev \
      libtalloc-dev libtins-dev libyaml-dev \
    && rm -rf /var/lib/apt/lists/*
RUN git clone --depth 1 --branch ${OPEN5GS_VERSION} https://github.com/open5gs/open5gs /open5gs
WORKDIR /open5gs
RUN meson setup build --prefix=/opt/open5gs --libdir=lib --buildtype=release \
    && ninja -C build install

FROM ubuntu:jammy
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates iproute2 iptables iputils-ping procps \
      libbson-1.0-0 libcurl3-gnutls libgcrypt20 libgnutls30 libidn12 \
      libmicrohttpd12 libmongoc-1.0-0 libnghttp2-14 libsctp1 libssl3 \
      libtalloc2 libtins4.0 libyaml-0-2 \
    && rm -rf /var/lib/apt/lists/*
COPY --from=open5gs-build /opt/open5gs /opt/open5gs
RUN printf "/opt/open5gs/lib\n/opt/open5gs/lib/x86_64-linux-gnu\n" > /etc/ld.so.conf.d/open5gs.conf && ldconfig
ENV PATH=/opt/open5gs/bin:$PATH
WORKDIR /opt/open5gs
