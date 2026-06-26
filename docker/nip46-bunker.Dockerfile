# Minimal NIP-46 bunker for local bot development.
# Builds only the Bunker46 server (no web UI) from source on GitHub.
FROM node:24-slim AS base
RUN apt-get update -y \
    && apt-get install -y --no-install-recommends openssl ca-certificates git \
    && rm -rf /var/lib/apt/lists/* \
    && corepack enable \
    && corepack prepare pnpm@10.10.0 --activate
WORKDIR /app

FROM base AS deps
ARG BUNKER46_REF=main
RUN git clone --depth 1 --branch "${BUNKER46_REF}" https://github.com/dsbaars/bunker46.git /src \
    && mkdir -p /app/apps/server /app/packages/tsconfig /app/packages/eslint-config /app/packages/shared-types /app/packages/config \
    && cp -r /src/pnpm-lock.yaml /src/pnpm-workspace.yaml /src/package.json /src/.npmrc /app/ \
    && cp -r /src/apps/server/package.json /app/apps/server/package.json \
    && cp -r /src/packages/tsconfig/package.json /app/packages/tsconfig/package.json \
    && cp -r /src/packages/eslint-config/package.json /app/packages/eslint-config/package.json \
    && cp -r /src/packages/shared-types/package.json /app/packages/shared-types/package.json \
    && cp -r /src/packages/config/package.json /app/packages/config/package.json \
    && cp -r /src/apps/server/prisma /app/apps/server/prisma \
    && cp /src/apps/server/prisma.config.ts /app/apps/server/prisma.config.ts
WORKDIR /app
ENV DATABASE_URL="postgresql://build:build@localhost:5432/build"
RUN pnpm install --frozen-lockfile --filter @bunker46/server...

FROM base AS build
COPY --from=deps /app/node_modules ./node_modules
COPY --from=deps /app/apps/server/node_modules ./apps/server/node_modules
COPY --from=deps /app/packages ./packages
COPY --from=deps /src/apps/server /app/apps/server
COPY --from=deps /src/packages /app/packages
WORKDIR /app/apps/server
ENV DATABASE_URL="postgresql://build:build@localhost:5432/build"
RUN pnpm exec prisma generate
WORKDIR /app
RUN pnpm --filter @bunker46/server... run build

FROM base AS production
RUN addgroup --system --gid 1001 bunker \
    && adduser --system --uid 1001 bunker
COPY --from=build /app/apps/server/dist ./dist
COPY --from=build /app/apps/server/prisma ./prisma
COPY --from=build /app/packages ./packages
COPY --from=deps /app/node_modules ./node_modules
COPY --from=deps /app/apps/server/node_modules ./apps/server/node_modules
COPY --from=build /app/apps/server/package.json ./package.json
COPY --from=build /app/apps/server/prisma.config.ts ./prisma.config.ts
COPY --from=deps /src/apps/server/docker-entrypoint.sh ./docker-entrypoint.sh
RUN chmod +x ./docker-entrypoint.sh

USER bunker
EXPOSE 3000
ENTRYPOINT ["./docker-entrypoint.sh"]
CMD ["node", "dist/main.js"]
