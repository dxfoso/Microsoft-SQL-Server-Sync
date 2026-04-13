FROM ghcr.io/cirruslabs/flutter:stable AS build

WORKDIR /app

ARG BACKEND_BASE_URL=http://localhost:9001
ARG BUILD_COMMIT_HASH=dev
ARG BUILD_COMMIT_DATE=unknown
ARG BUILD_RELEASE_DATE=unknown

ENV BACKEND_BASE_URL=${BACKEND_BASE_URL}
ENV BUILD_COMMIT_HASH=${BUILD_COMMIT_HASH}
ENV BUILD_COMMIT_DATE=${BUILD_COMMIT_DATE}
ENV BUILD_RELEASE_DATE=${BUILD_RELEASE_DATE}

COPY pubspec.yaml pubspec.lock ./
RUN flutter pub get

COPY . .
RUN flutter build web --release \
  --dart-define=BACKEND_BASE_URL=${BACKEND_BASE_URL} \
  --dart-define=BUILD_COMMIT_HASH=${BUILD_COMMIT_HASH} \
  --dart-define=BUILD_COMMIT_DATE=${BUILD_COMMIT_DATE} \
  --dart-define=BUILD_RELEASE_DATE=${BUILD_RELEASE_DATE}

FROM node:20-alpine

WORKDIR /app

COPY server.js /app/server.js
COPY --from=build /app/build/web /app/public

ENV PORT=80
ENV PUBLIC_DIR=/app/public
ENV STATE_FILE=/app/data/state.json

RUN mkdir -p /app/data

EXPOSE 80

CMD ["node", "server.js"]
