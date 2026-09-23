FROM node:24-trixie-slim

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    chromium chromium-sandbox fonts-noto-core fonts-noto-cjk fonts-noto-color-emoji \
    iptables \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --no-audit --no-fund
COPY server.js start.sh ./

EXPOSE 8080
CMD ["./start.sh"]
