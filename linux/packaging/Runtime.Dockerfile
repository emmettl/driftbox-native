# Deliberately independent of the Swift builder: no toolchain or development headers.
FROM ubuntu:24.04
# dbus-x11 satisfies the session-bus dependency without pulling in systemd/systemd-dev.
RUN apt-get update && apt-get install -y --no-install-recommends \
    libgtk-4-1 libegl1 libgles2 libegl-mesa0 libgl1-mesa-dri \
    libpipewire-0.3-0 libasound2t64 fonts-dejavu-core \
    python3 desktop-file-utils shared-mime-info \
    xvfb xauth dbus-daemon dbus-x11 \
    && rm -rf /var/lib/apt/lists/*
RUN useradd --create-home --uid 10001 tester
COPY scripts/test-linux-runtime.py /test-linux-runtime.py
USER tester
ENV HOME=/home/tester LIBGL_ALWAYS_SOFTWARE=1 GTK_A11Y=none
WORKDIR /home/tester
ENTRYPOINT ["python3", "/test-linux-runtime.py"]
CMD ["/packages"]
