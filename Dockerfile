# テストする Ubuntu の版。NLnet Labs のリポジトリに Routinator がある版 (22.04 / 24.04 / 26.04 など) を書く
ARG UBUNTU_VERSION=22.04
FROM ubuntu:${UBUNTU_VERSION}

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


# 入れる Routinator の版 (空なら最新版)。0.15.3 / 0.16.0~rc1 (rc 版) / 0.15.3-1jammy (パッケージの版) の形で書ける
ARG ROUTINATOR_VERSION=""

# 取得元はイメージの Ubuntu の codename (jammy / noble / resolute など) に合わせる
RUN . /etc/os-release \
    && curl -fsSL https://packages.nlnetlabs.nl/aptkey.asc \
        | tee /usr/share/keyrings/nlnetlabs-archive-keyring.asc > /dev/null \
    && echo "deb [signed-by=/usr/share/keyrings/nlnetlabs-archive-keyring.asc] \
https://packages.nlnetlabs.nl/linux/ubuntu/ ${VERSION_CODENAME} main" \
        > /etc/apt/sources.list.d/nlnetlabs.list \
    && case "${ROUTINATOR_VERSION}" in \
        *~rc*) echo "deb [signed-by=/usr/share/keyrings/nlnetlabs-archive-keyring.asc] \
https://packages.nlnetlabs.nl/linux/ubuntu/ ${VERSION_CODENAME}-proposed main" \
            >> /etc/apt/sources.list.d/nlnetlabs.list ;; \
    esac \
    && case "${ROUTINATOR_VERSION}" in \
        "")  pkg="routinator" ;; \
        *-*) pkg="routinator=${ROUTINATOR_VERSION}" ;; \
        *)   pkg="routinator=${ROUTINATOR_VERSION}-*" ;; \
    esac \
    && apt-get update \
    && apt-get install -y "${pkg}"


RUN useradd -m -s /bin/bash testuser \
    && echo "testuser ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers


WORKDIR /opt/routinator-tests
COPY *.sh ./
RUN chmod +x *.sh && chown -R testuser:testuser /opt/routinator-tests



CMD ["bash"]

