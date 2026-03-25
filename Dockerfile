FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive


RUN apt-get update && apt-get install -y \
        ca-certificates \
        curl \
        gnupg \
        iproute2 \
        lsb-release \
        lsof \
        netcat-openbsd \
        procps \
        python3 \
        sudo \
        xxd


RUN curl -fsSL https://packages.nlnetlabs.nl/aptkey.asc \
        | tee /usr/share/keyrings/nlnetlabs-archive-keyring.asc > /dev/null \
    && echo "deb [signed-by=/usr/share/keyrings/nlnetlabs-archive-keyring.asc] \
https://packages.nlnetlabs.nl/linux/ubuntu/ jammy main" \
        > /etc/apt/sources.list.d/nlnetlabs.list \
    && apt-get update \
    && apt-get install -y routinator


RUN useradd -m -s /bin/bash testuser \
    && echo "testuser ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers


WORKDIR /opt/routinator-tests
COPY *.sh ./
RUN chmod +x *.sh && chown -R testuser:testuser /opt/routinator-tests



CMD ["bash"]
