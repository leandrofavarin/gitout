# Tools to support cross-compilation
FROM --platform=$BUILDPLATFORM tonistiigi/xx AS xx


FROM --platform=$BUILDPLATFORM rust:1.81.0 AS rust
COPY --from=xx / /
ARG TARGETPLATFORM
RUN case "$TARGETPLATFORM" in \
  "linux/amd64") echo x86_64-unknown-linux-gnu > /rust_target.txt ;; \
  "linux/arm64") echo aarch64-unknown-linux-gnu > /rust_target.txt ;; \
  *) exit 1 ;; \
esac
RUN case "$TARGETPLATFORM" in \
  "linux/amd64") echo gcc-x86-64-linux-gnu > /gcc.txt ;; \
  "linux/arm64") echo gcc-aarch64-linux-gnu > /gcc.txt ;; \
  *) exit 1 ;; \
esac
RUN rustup target add $(cat /rust_target.txt)
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    $(cat /gcc.txt)
    # libssl-dev 
RUN rustup component add clippy rustfmt
WORKDIR /app
COPY Cargo.toml Cargo.lock .rustfmt.toml ./
COPY src ./src
RUN cargo build -v --release --target $(cat /rust_target.txt) --config net.git-fetch-with-cli=true
# Move the binary to a location free of the target since that is not available in the next stage.
RUN cp target/$(cat /rust_target.txt)/release/gitout .
RUN xx-verify ./gitout
RUN cargo clippy
RUN cargo test
RUN cargo fmt -- --check


FROM golang:1.18-alpine AS shell
RUN apk add --no-cache shellcheck
ENV GO111MODULE=on
RUN go install mvdan.cc/sh/v3/cmd/shfmt@latest
WORKDIR /overlay
COPY root/ ./
COPY .editorconfig /
RUN find . -type f | xargs shellcheck -e SC1008
RUN shfmt -d .


FROM --platform=$BUILDPLATFORM debian:buster-slim
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      wget
ARG TARGETPLATFORM
# ADD isn't a shell command thus doesn't allow resolving a variable
# https://github.com/just-containers/s6-overlay/issues/512
RUN \
    # Extract the architecture part (e.g., amd64, arm64)
    ARCH=$(echo "$TARGETPLATFORM" | cut -d '/' -f2) && \
    if [ "$ARCH" = "amd64" ]; then \
      echo https://github.com/just-containers/s6-overlay/releases/download/v2.2.0.1/s6-overlay-amd64-installer > /s6-url.txt ; \
    elif [ "$ARCH" = "arm64" ]; then \
      echo https://github.com/just-containers/s6-overlay/releases/download/v2.2.0.1/s6-overlay-aarch64-installer > /s6-url.txt ; \
    else \
      echo "Unsupported architecture: $ARCH"; exit 1; \
    fi
RUN wget --no-check-certificate $(cat /s6-url.txt) -O /tmp/installer
RUN chmod +x /tmp/installer && /tmp/installer /

ENV \
    # Fail if cont-init scripts exit with non-zero code.
    S6_BEHAVIOUR_IF_STAGE2_FAILS=2 \
    # Show full backtraces for crashes.
    RUST_BACKTRACE=full \
    CRON="" \
    HEALTHCHECK_ID="" \
    HEALTHCHECK_HOST="https://hc-ping.com" \
    PUID="" \
    PGID="" \
    GITOUT_ARGS=""
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        curl \
      && \
    rm -rf /var/lib/apt/lists/*
COPY root/ /
WORKDIR /app
COPY --from=rust /app/gitout ./
