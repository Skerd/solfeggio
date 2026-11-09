# syntax=docker/dockerfile:1
# Build from the deploy folder (must contain armonia/ and maestro/):
#   docker build -f apps/maestro/Dockerfile -t arpeggio-maestro:latest deploy/
#
# Maestro declares `"armonia": "../armonia"`; that directory must sit next to maestro
# under the build context. A context of only maestro/ breaks that link and npm install.
#
# Three stages (D106): `base` has the build toolchain, `build` installs, type-checks, tests and emits the JavaScript,
# then drops maestro's and armonia's dev dependencies; `runtime` is the slim image of the same Debian release with only the programs the
# servers run (ghostscript, ffmpeg) and the compiled output + production dependencies (TD-B118).

FROM node:22.14.0-bookworm AS base

WORKDIR /

# Native toolchain + headers for node-canvas (Cairo/Pango/PNG/fonts), ffmpeg for fluent-ffmpeg,
# and extra Node heap for opencv.js (Emscripten/WASM) during load (sharp ships its own binaries).
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    python3 \
    pkg-config \
    libcairo2-dev \
    libpango1.0-dev \
    libjpeg62-turbo-dev \
    libgif-dev \
    librsvg2-dev \
    libpixman-1-dev \
    libpng-dev \
    libfreetype6-dev \
    libfontconfig1-dev \
    ghostscript \
    ca-certificates \
    ffmpeg \
    && rm -rf /var/lib/apt/lists/*

# Emscripten/OpenCV.js allocates a large static heap; avoid OOM during require() in small containers.
ENV NODE_OPTIONS="--max-old-space-size=6144"

FROM base AS build

# Armonia deps — cached unless package.json / lockfile change.
# npm 10.9.2 (node:22.14.0) crashes in arborist on vitest 4 optional peers
# ("Cannot read properties of null (reading 'edgesOut')") when installing from
# package.json alone. Lockfile + --legacy-peer-deps; npm i not ci because the
# lockfile still has zod ^4.3.6 while package.json pins 4.3.6.
WORKDIR /armonia
COPY armonia/package.json armonia/package-lock.json ./
RUN --mount=type=cache,target=/root/.npm npm i --no-audit --no-fund --legacy-peer-deps

COPY armonia ./
# Deploy gate (D07/D08): `build` type-checks armonia; its tests must pass too, or no image is built.
RUN npm run build && npx vitest run

# Maestro deps + native addons — cached unless package.json changes.
WORKDIR /maestro
COPY maestro/package.json ./
RUN --mount=type=cache,target=/root/.npm npm install --no-audit --no-fund --ignore-scripts

RUN npm rebuild bcrypt canvas sharp --foreground-scripts

COPY maestro ./
COPY scripts/ ./scripts/

# Deploy gate (D07/D08) and build (D106): the modules assembled for this instance must type-check and pass their
# tests, or no image is built. One `tsc` emit is both the type check and the build (`noEmitOnError`). The tests start
# in-memory MongoDB (cached between builds); its version has no Debian 12 build for every CPU, so it uses the Ubuntu
# 22.04 build, which runs on this image. The runtime assets are copied after the tests, so vitest's tsconfig-paths
# never finds dist/maestro/tsconfig.json.
RUN --mount=type=cache,target=/root/.cache/mongodb-binaries \
    node_modules/.bin/tsc -p tsconfig.build.json && MONGOMS_DISTRO=ubuntu-22.04 npx vitest run \
    && node scripts/build/copyRuntimeAssets.mjs

# After the gate, maestro and armonia keep only their production dependencies; --ignore-scripts keeps the rebuilt addons.
# The prune must leave node_modules/armonia as the `../armonia` link.
RUN npm prune --omit=dev --ignore-scripts --no-audit --no-fund \
    && cd /armonia && npm prune --omit=dev --ignore-scripts --no-audit --no-fund --legacy-peer-deps \
    && test -L /maestro/node_modules/armonia

# Same Debian release as the build, so the addons built there load here. bcrypt needs only libstdc++; canvas ships its
# Cairo/Pango libraries inside its prebuilt binary and needs fontconfig's fonts; sharp bundles libvips. ghostscript and
# ffmpeg are programs the servers run (floor-plan PDF import, media uploads); they also bring the fonts canvas uses.
FROM node:22.14.0-bookworm-slim AS runtime

RUN apt-get update && apt-get install -y --no-install-recommends \
    ghostscript \
    ffmpeg \
    fonts-dejavu-core \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

ENV NODE_OPTIONS="--max-old-space-size=6144"
ENV NODE_ENV=production

# Same layout as the sources: /armonia beside /maestro, so `armonia/*` (tsconfig paths) and the `../armonia`
# dependency link resolve to the compiled armonia.
COPY --from=build /armonia/node_modules /armonia/node_modules
COPY --from=build /maestro/dist/armonia /armonia
COPY --from=build /maestro/node_modules /maestro/node_modules
COPY --from=build /maestro/dist/maestro /maestro

WORKDIR /maestro

# No image if a native addon cannot load its libraries on this base.
RUN node -e "require('bcrypt'); require('canvas'); require('sharp')"

EXPOSE 81

CMD ["npm", "run", "api"]
