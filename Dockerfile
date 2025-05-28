FROM alpine AS builder

ARG ZEEK_VERSION=6.2.1
# ARG AF_PACKET_VERSION=3.0.2 # Not used in the provided snippet
ARG BUILD_PROCS=4
ARG LIBRDKAFKA_VERSION=1.4.4
ARG ZKG_VERSION=3.0.1 # Assuming this ARG is available globally or passed
ARG ZEEK_KAFKA_PLUGIN_VERSION=v1.2.0

# Install all build dependencies needed for Zeek, librdkafka, and zkg C++ plugins
# Added: curl, tar, gzip (for fetching sources), cyrus-sasl-dev (for librdkafka SASL), python3, py3-pip (for zkg)
RUN apk add --no-cache -t .combined-build-deps \
    bsd-compat-headers \
    libmaxminddb-dev \
    linux-headers \
    openssl-dev \
    libpcap-dev \
    python3-dev \
    zlib-dev \
    flex-dev \
    binutils \
    fts-dev \
    cmake \
    bison \
    bash \
    swig \
    perl \
    make \
    flex \
    git \
    gcc \
    g++ \
    fts \
    krb5-dev \
    curl \
    tar \
    gzip \
    cyrus-sasl-dev \
    python3 \
    py3-pip

RUN echo "===> Cloning zeek..." \
    && cd /tmp \
    && git clone --recursive --branch v$ZEEK_VERSION https://github.com/zeek/zeek.git

RUN echo "===> Compiling zeek..." \
    && cd /tmp/zeek \
    && CC=gcc ./configure --prefix=/usr/local/zeek \
    --build-type=Release \
    --disable-broker-tests \
    --disable-auxtools \
    --disable-javascript \
    && make -j $BUILD_PROCS \
    && make install

RUN echo "===> Building and installing librdkafka v${LIBRDKAFKA_VERSION} to /usr/local..." \
    && cd /tmp \
    && curl -L https://github.com/edenhill/librdkafka/archive/refs/tags/v${LIBRDKAFKA_VERSION}.tar.gz | tar xvz \
    && cd librdkafka-${LIBRDKAFKA_VERSION}/ \
    # Configure with SASL enabled, installing to /usr/local for zkg to find
    && ./configure --prefix=/usr/local --enable-sasl \
    && make -j ${BUILD_PROCS} \
    && make install \
    && rm -rf /tmp/librdkafka-${LIBRDKAFKA_VERSION}

# Set PATH to include zeek-config for zkg
ENV PATH=/usr/local/zeek/bin:$PATH

RUN echo "===> Installing zkg and zeek-kafka plugin v${ZEEK_KAFKA_PLUGIN_VERSION}..." \
    # Install zkg using pip
    && pip install --break-system-packages zkg==$ZKG_VERSION \
    # Initialize zkg configuration
    && zkg autoconfig \
    # Non-interactively configure LIBRDKAFKA_ROOT for the zeek-kafka plugin
    # zkg stores its config in /root/.zkg/config by default in a root context
    && mkdir -p /root/.zkg \
    && echo "" >> /root/.zkg/config \
    && echo "[zeek/seisollc/zeek-kafka]" >> /root/.zkg/config \
    && echo "LIBRDKAFKA_ROOT = /usr/local" >> /root/.zkg/config \
    # Install the zeek-kafka plugin
    && zkg install seisollc/zeek-kafka --version $ZEEK_KAFKA_PLUGIN_VERSION \
    # Verify plugin installation (optional, but good for checking)
    && /usr/local/zeek/bin/zeek -N Seiso::Kafka \
    # Clean up caches
    && rm -rf /root/.zkg/cache /root/.cache/pip

RUN echo "===> Shrinking image..." \
    && strip -s /usr/local/zeek/bin/zeek

RUN echo "===> Size of the Zeek install..." \
    && du -sh /usr/local/zeek

# Clean up all combined build dependencies at the end of the builder stage
RUN apk del .combined-build-deps

####################################################################################################
FROM alpine AS final

# python3 & bash are needed for zeekctl scripts
# ethtool is needed to manage interface features
# util-linux provides taskset command needed to pin CPUs
# py3-pip and git are needed for zeek's package manager
# Added cyrus-sasl for librdkafka runtime SASL support
RUN apk --no-cache add \
    ca-certificates zlib openssl libstdc++ libpcap libmaxminddb libgcc fts krb5-libs \
    python3 bash \
    ethtool \
    util-linux \
    py3-pip git \
    cyrus-sasl

RUN ln -s $(which ethtool) /sbin/ethtool

# Copy Zeek installation (now includes zeek-kafka plugin) from builder
COPY --from=builder /usr/local/zeek /usr/local/zeek
# Copy librdkafka runtime libraries from builder
COPY --from=builder /usr/local/lib/librdkafka.so* /usr/local/lib/
COPY --from=builder /usr/local/lib/librdkafka++.so* /usr/local/lib/

# Ensure the system's dynamic linker can find the new libraries in /usr/local/lib
# Alpine typically checks /usr/local/lib by default, but this is an explicit measure.
# Add libc-utils if ldconfig is needed and not present (usually it is on base alpine)
# RUN apk add --no-cache libc-utils
RUN echo "/usr/local/lib" > /etc/ld.so.conf.d/usr-local-lib.conf && ldconfig || true

ENV ZEEKPATH=.:/usr/local/zeek/share/zeek:/usr/local/zeek/share/zeek/policy:/usr/local/zeek/share/zeek/site
ENV PATH=$PATH:/usr/local/zeek/bin

# Install Zeek package manager (zkg)
ARG ZKG_VERSION=3.0.1 # This ARG must be available here
ARG ZEEK_DEFAULT_PACKAGES="bro-interface-setup bro-doctor ja3 zeek-open-connections" # This ARG must be available

RUN pip install --break-system-packages zkg==$ZKG_VERSION \
    && zkg autoconfig \
    && zkg refresh \
    # These default packages are assumed to be script-based or their C++ deps are minimal/covered.
    # The zeek-kafka C++ plugin is already built and included from the builder stage.
    && zkg install --force $ZEEK_DEFAULT_PACKAGES \
    # Clean up zkg and pip cache
    && rm -rf /root/.zkg/cache /root/.cache/pip


ARG ZEEKCFG_VERSION=0.0.5 # This ARG must be available

# Set TARGET_ARCH to Docker build host arch unless TARGETARCH is specified via BuildKit
RUN case `uname -m` in \
    x86_64) \
        TARGET_ARCH="amd64" \
        ;; \
    aarch64) \
        TARGET_ARCH="arm64" \
        ;; \
    arm|armv7l) \
        TARGET_ARCH="arm" \
        ;; \
    esac; \
    TARGET_ARCH=${TARGETARCH:-$TARGET_ARCH}; \
    echo https://github.com/activecm/zeekcfg/releases/download/v${ZEEKCFG_VERSION}/zeekcfg_${ZEEKCFG_VERSION}_linux_${TARGET_ARCH}; \
    wget -qO /usr/local/zeek/bin/zeekcfg https://github.com/activecm/zeekcfg/releases/download/v${ZEEKCFG_VERSION}/zeekcfg_${ZEEKCFG_VERSION}_linux_${TARGET_ARCH} \
    && chmod +x /usr/local/zeek/bin/zeekcfg

# Run zeekctl cron to heal processes every 5 minutes
RUN echo "*/5      * * * * /usr/local/zeek/bin/zeekctl cron" >> /etc/crontabs/root
COPY docker-entrypoint.sh /docker-entrypoint.sh

# Users must supply their own node.cfg
RUN rm -f /usr/local/zeek/etc/node.cfg
COPY etc/networks.cfg /usr/local/zeek/etc/networks.cfg
COPY etc/zeekctl.cfg /usr/local/zeek/etc/zeekctl.cfg
COPY share/zeek/site/ /usr/local/zeek/share/zeek/site/

CMD ["/docker-entrypoint.sh"]
