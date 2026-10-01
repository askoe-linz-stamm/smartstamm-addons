# Home Assistant base image (bashio, curl, jq). The measurement clients are not
# part of the image: the Ookla CLI may not be redistributed (EULA) and the RMBT
# client is fetched from this repository's releases; run.sh downloads both into
# the add-on data directory on first start.
ARG BUILD_FROM=ghcr.io/home-assistant/aarch64-base:3.24
FROM ${BUILD_FROM}
# Pull current Alpine packages at every (re)build; the update workflow bumps the
# add-on version every three days so the device rebuilds the image.
RUN apk upgrade --no-cache && apk add --no-cache python3 py3-cryptography
COPY run.sh /run.sh
COPY schedule.sh /schedule.sh
COPY options.sh /options.sh
COPY rtr_servers.json /rtr_servers.json
COPY router.py /router.py
RUN chmod +x /run.sh
ARG BUILD_ARCH
ARG BUILD_VERSION
LABEL io.hass.type="addon" io.hass.arch="${BUILD_ARCH}" io.hass.version="${BUILD_VERSION}" \
      io.hass.name="SmartStamm Netzmessung" io.hass.description="Scheduled internet speed measurements"
CMD ["/run.sh"]
