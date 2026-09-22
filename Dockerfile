# syntax=docker/dockerfile:1
FROM ubuntu:24.04 AS builder
ARG DEBIAN_FRONTEND=noninteractive
ARG BUILD_JOBS=8
ARG YOSYS_COMMIT=70a11c6bf0e8dd669f56c7da3587f78b405138e2
ARG ASAP7_COMMIT=f970bd3c3292b79ae4d022a3ec80533534614066
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential bison flex gawk tcl-dev libffi-dev libreadline-dev \
    pkg-config python3 zlib1g-dev git ca-certificates curl p7zip-full libfl-dev \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src/yosys
RUN git init && git remote add origin https://github.com/YosysHQ/yosys.git \
    && git fetch --depth 1 origin "$YOSYS_COMMIT" && git checkout --detach FETCH_HEAD \
    && git submodule update --init --recursive --depth 1 \
    && make config-gcc && make -j"$BUILD_JOBS" PREFIX=/opt/yosys \
    && make install PREFIX=/opt/yosys \
    && cp COPYING /opt/yosys/LICENSE
RUN mkdir -p /opt/asap7/lib /opt/asap7/licenses \
    && base="https://raw.githubusercontent.com/The-OpenROAD-Project/asap7sc7p5t_28/$ASAP7_COMMIT" \
    && for name in AO_RVT_TT_nldm_211120 INVBUF_RVT_TT_nldm_220122 \
        OA_RVT_TT_nldm_211120 SEQ_RVT_TT_nldm_220123 SIMPLE_RVT_TT_nldm_211120; do \
        curl -fL --retry 3 "$base/LIB/NLDM/asap7sc7p5t_$name.lib.7z" -o /tmp/cells.7z \
        && 7z e -y -o/opt/asap7/lib /tmp/cells.7z || exit 1; \
    done \
    && curl -fL --retry 3 "$base/LICENSE" -o /opt/asap7/licenses/LICENSE \
    && printf 'Yosys 0.63: %s\nASAP7 7.5-track r28 RVT TT NLDM: %s\n' \
        "$YOSYS_COMMIT" "$ASAP7_COMMIT" > /opt/versions.txt \
    && cd /opt/asap7 && sha256sum lib/*.lib > SHA256SUMS
RUN strip /opt/yosys/bin/yosys /opt/yosys/bin/yosys-abc

FROM ubuntu:24.04 AS sta-builder
ARG DEBIAN_FRONTEND=noninteractive
ARG BUILD_JOBS=8
ARG OPENSTA_COMMIT=f89887b59600cd3a2a10c3de31bda4235d904cdf
ARG CUDD_COMMIT=f54f533303640afd5dbe47a05ebeabb3066f2a25
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential cmake bison flex libfl-dev swig tcl-dev zlib1g-dev libeigen3-dev \
    git ca-certificates autoconf automake libtool \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src/cudd
RUN git init && git remote add origin https://github.com/ivmai/cudd.git \
    && git fetch --depth 1 origin "$CUDD_COMMIT" && git checkout --detach FETCH_HEAD \
    && autoreconf -fi && ./configure --prefix=/opt/cudd --enable-shared=no \
    && make -j"$BUILD_JOBS" && make install
WORKDIR /src/opensta
RUN git init && git remote add origin https://github.com/The-OpenROAD-Project/OpenSTA.git \
    && git fetch --depth 1 origin "$OPENSTA_COMMIT" && git checkout --detach FETCH_HEAD \
    && cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DCUDD_DIR=/opt/cudd \
        -DCMAKE_INSTALL_PREFIX=/opt/opensta -DUSE_TCL_READLINE=OFF -DBUILD_TESTS=OFF \
    && cmake --build build -j"$BUILD_JOBS" && cmake --install build \
    && strip /opt/opensta/bin/sta \
    && mkdir -p /opt/opensta/licenses \
    && cp LICENSE /opt/opensta/licenses/OpenSTA \
    && cp /src/cudd/LICENSE /opt/opensta/licenses/CUDD \
    && printf 'OpenSTA: %s\nCUDD: %s\n' "$OPENSTA_COMMIT" "$CUDD_COMMIT" \
        > /opt/opensta/versions.txt

FROM ubuntu:24.04
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    tcl libffi8 libreadline8t64 zlib1g python3 ca-certificates \
    build-essential verilator \
    && rm -rf /var/lib/apt/lists/*
COPY --from=builder /opt/yosys /opt/yosys
COPY --from=builder /opt/asap7 /opt/asap7
COPY --from=builder /opt/versions.txt /opt/versions.txt
COPY --from=sta-builder /opt/opensta /opt/opensta
RUN cat /opt/opensta/versions.txt >> /opt/versions.txt
ENV PATH="/opt/yosys/bin:/opt/opensta/bin:${PATH}"
COPY scripts/build.py scripts/run.py scripts/synth.py scripts/synth_report.py scripts/timing.py scripts/timing.tcl scripts/fakeram.py scripts/testcase.py scripts/oj_io.py scripts/toolchain.py scripts/sim.cpp /opt/cpu2026/
COPY scripts/ram /opt/cpu2026/ram
COPY testcases /opt/cpu2026/testcases
RUN chmod +x /opt/cpu2026/*.py \
    && ln -s /opt/cpu2026/build.py /usr/local/bin/build \
    && ln -s /opt/cpu2026/run.py /usr/local/bin/run \
    && ln -s /opt/cpu2026/synth.py /usr/local/bin/synth
WORKDIR /work
ENTRYPOINT []
CMD ["bash"]
