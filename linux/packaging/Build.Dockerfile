# Match the runtime baseline; compile natively on each architecture.
# Multiarchitecture index: changing Swift requires requalifying linux/licenses as well.
FROM swift:6.4-noble@sha256:64bab762bc73a3fda6d9ebc559258bd6d7660c10a705bb25ecacad2f99d066f9
RUN apt-get update && apt-get install -y --no-install-recommends \
    libegl-dev libgles-dev libpipewire-0.3-dev libasound2-dev libgtk-4-dev python3 dpkg-dev desktop-file-utils \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY Package.swift LICENSE ./
COPY Sources Sources
COPY Tests Tests
ARG JOBS=4
RUN swift build --scratch-path /build -c release -j "$JOBS" --product driftbox-linux
COPY linux linux
COPY windows/Driftbox.ico windows/Driftbox.ico
COPY scripts/linux-package.py scripts/linux-deb.py scripts/version.env scripts/
ARG SOURCE_REVISION
ARG SOURCE_DIRTY
ARG SOURCE_DATE_EPOCH
ENV SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH
RUN python3 scripts/linux-package.py --build-dir /build/release --toolchain / \
    --output /dist --source-revision "$SOURCE_REVISION" --source-dirty "$SOURCE_DIRTY" \
    && python3 scripts/linux-deb.py --bundle /dist/Driftbox-*-preview-*/ --output /dist \
    && mkdir /out && cp /dist/*.tar.gz /dist/*.deb /dist/*.sha256 /out/
