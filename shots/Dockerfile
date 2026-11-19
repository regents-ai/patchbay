# node:26.13.1-trixie-slim
FROM docker.io/library/node@sha256:e6bedef217677b276c591795e169840edd9096dbf13f29df8ef8d1856b8820bc

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
