# Shenzhen Friends host. Build context: the package root (portable/server/friends, or /opt/stacks/friends/src on
# the server), e.g. `docker compose build` with deploy/docker-compose.yml, or
#   docker build -f deploy/Dockerfile --target test .     # runs the suite inside the image first
#
# Node 22 is the floor (ADR 0005: node:sqlite unflagged with its busy timeout from 22.16). node:sqlite is still
# experimental in the 22 line, so the image is pinned by digest (DEPLOY.md, "Pin the Node image") and moved only
# with the test stage green. There is no default: the build stops in deploy/check-node-image.sh unless NODE_IMAGE
# ends in @sha256:<digest>.
ARG NODE_IMAGE

FROM ${NODE_IMAGE} AS deps
ARG NODE_IMAGE
WORKDIR /app
COPY deploy/check-node-image.sh /tmp/check-node-image.sh
RUN sh /tmp/check-node-image.sh "$NODE_IMAGE" && rm /tmp/check-node-image.sh
COPY package.json package-lock.json ./
# Exactly the lockfile (ws, checked against its sha512 integrity); no install scripts run.
RUN npm ci --omit=dev --ignore-scripts --no-audit --no-fund && npm cache clean --force

FROM deps AS test
COPY src ./src
COPY tools ./tools
COPY test ./test
# Some tests check the deploy files themselves (nginx block, compose limits, digest pinning).
COPY deploy ./deploy
# The helper's bundled list and pinned keys live outside this package; the two tests that read them run in the
# repository's suite instead.
RUN FRIENDS_TEST_STANDALONE=1 node --disable-warning=ExperimentalWarning --test test/*.test.js

FROM ${NODE_IMAGE} AS runtime
WORKDIR /app
# uid 10001, like the server's other stacks; /data is the only writable path (the root filesystem is read-only).
RUN adduser -D -H -u 10001 friends && mkdir /data && chown 10001:10001 /data && chmod 700 /data
COPY --from=deps /app/node_modules ./node_modules
COPY package.json ./
COPY src ./src
COPY tools ./tools
ENV NODE_ENV=production \
    FRIENDS_DATA_DIR=/data \
    FRIENDS_LISTEN_HOST=0.0.0.0 \
    FRIENDS_LISTEN_PORT=8080
USER 10001:10001
EXPOSE 8080
# /healthz answers on the container's own port only; the ingress proxies /v1 and nothing else.
HEALTHCHECK --interval=30s --timeout=5s --retries=3 CMD wget -q -O /dev/null http://127.0.0.1:8080/healthz || exit 1
CMD ["node", "--disable-warning=ExperimentalWarning", "src/main.js"]
