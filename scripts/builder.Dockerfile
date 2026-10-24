# Builder image for docker-build.sh: the target distro with the build dependencies
# preinstalled, so local builds don't run apt every time.
ARG BASE=debian:trixie
FROM ${BASE}
COPY common.sh install-deps.sh /opt/obs-jfmpp/scripts/
RUN /opt/obs-jfmpp/scripts/install-deps.sh && rm -rf /var/lib/apt/lists/*
