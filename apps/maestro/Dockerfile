# syntax=docker/dockerfile:1
# Build from the deploy folder (must contain armonia/ and maestro/):
#   docker build -f apps/maestro/Dockerfile -t arpeggio-maestro:latest deploy/
#
# Maestro declares `"armonia": "../armonia"`; that directory must sit next to maestro
# under the build context. A context of only maestro/ breaks that link and npm install.

FROM node:22.14.0-bookworm

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

# Deploy gate (D07/D08): the modules assembled for this instance must type-check and pass their tests, or no image
# is built. The tests start in-memory MongoDB (cached between builds); its version has no Debian 12 build for every
# CPU, so it uses the Ubuntu 22.04 build, which runs on this image.
RUN --mount=type=cache,target=/root/.cache/mongodb-binaries \
    node_modules/.bin/tsc --noEmit -p . && MONGOMS_DISTRO=ubuntu-22.04 npx vitest run

EXPOSE 81

CMD ["npm", "run", "api"]
