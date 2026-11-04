# node:26.13.0-trixie-slim
FROM docker.io/library/node@sha256:e4db4c914bf8ad241bd24804fc25d272d89bad97e68cdc8a1414862790a02c39

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    chromium chromium-sandbox fonts-noto-core fonts-noto-cjk fonts-noto-color-emoji \
    nftables \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --no-audit --no-fund
COPY server.js start.sh ./

EXPOSE 8080
CMD ["./start.sh"]
