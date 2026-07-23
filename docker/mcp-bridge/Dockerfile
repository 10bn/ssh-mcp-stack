FROM node:20-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends dumb-init \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci --omit=dev

COPY auth-proxy.js entrypoint.sh ./
RUN chmod +x entrypoint.sh

ENV PORT=8000 \
    INTERNAL_PORT=8001 \
    OUTPUT_TRANSPORT=sse \
    SSH_CONFIG_FILE=/config/ssh-config.json

EXPOSE 8000

ENTRYPOINT ["dumb-init", "--"]
CMD ["./entrypoint.sh"]
