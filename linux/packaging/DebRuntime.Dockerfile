# Dedicated context assembled by linux-package-ci.sh; no source tree or Swift toolchain.
FROM ubuntu:24.04
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 xvfb xauth dbus-x11 \
    && useradd --create-home --uid 10001 tester
# Ubuntu's minimized container filters documentation by default. Keep our package's
# docs so dpkg verification and obsolete-document upgrade checks match a desktop install.
RUN printf 'path-include=/usr/share/doc/driftbox-linux-preview\npath-include=/usr/share/doc/driftbox-linux-preview/*\n' > /etc/dpkg/dpkg.cfg.d/zz-driftbox-test
COPY *.deb /packages/
# Fetch dependencies without installing them. The test must install them itself with
# networking disabled, proving that Depends is sufficient from this minimal baseline.
RUN rm -f /etc/apt/apt.conf.d/docker-clean \
    && apt-get install -y --download-only --no-install-recommends /packages/*.deb \
    && rm /packages/*.deb
COPY test-linux-deb-runtime.py /test-linux-deb-runtime.py
WORKDIR /home/tester
ENTRYPOINT ["python3", "/test-linux-deb-runtime.py"]
CMD ["/packages"]
