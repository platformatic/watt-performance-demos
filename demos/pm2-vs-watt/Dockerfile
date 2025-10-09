FROM node:20-alpine

ARG COMMIT_HASH
ARG BUILD_TIME

WORKDIR /app

COPY . ./

RUN npm install --omit=dev && npm cache clean --force

RUN chmod +x entrypoint.sh

EXPOSE 3000-3004

ENV HOSTNAME=0.0.0.0

CMD "./entrypoint.sh"

LABEL org.opencontainers.image.authors="Platformatic"
LABEL org.opencontainers.image.created="$BUILD_TIME"
LABEL org.opencontainers.image.revision="$COMMIT_HASH"
LABEL org.opencontainers.image.licenses="Apache-2.0"
LABEL org.opencontainers.image.source="https://github.com/platformatic/watt-performance-demos"
LABEL org.opencontainers.image.title="pm2-vs-watt demo"
LABEL org.opencontainers.image.description="pm2 vs watt demo servers"
