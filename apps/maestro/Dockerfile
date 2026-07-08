# Build from the deploy folder (must contain armonia/ and maestro/):
#   docker build -f apps/maestro/Dockerfile -t arpeggio-maestro:latest deploy/
#
# Maestro declares `"armonia": "../armonia"`; that directory must sit next to maestro
# under the build context. A context of only maestro/ breaks that link and npm install.

FROM node:22.14.0-bookworm

WORKDIR /

# Native toolchain + headers for node-canvas (Cairo/Pango/PNG/fonts), ffmpeg for fluent-ffmpeg,
# libopencv-dev + cmake for @u4/opencv4nodejs (node-gyp against system OpenCV; maestro disables auto-build),
# and extra Node heap for opencv.js (Emscripten/WASM) during load (sharp ships its own binaries).
ENV OPENCV4NODEJS_DISABLE_AUTOBUILD=1

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    cmake \
    python3 \
    pkg-config \
    libopencv-dev \
    libopencv-contrib-dev \
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

COPY armonia ./armonia
WORKDIR /armonia
RUN npm i
# Zod v4: explicit ZodPipe return type on preprocess() fails tsc; infer from z.preprocess().
RUN sed -i 's/function withNumericFormDataPreprocess<T extends z.ZodTypeAny>(inner: T): z.ZodPipe<z.ZodTransform<unknown, unknown>, T> {/function withNumericFormDataPreprocess<T extends z.ZodTypeAny>(inner: T) {/' src/modules/core/helpers/zodBuilder.ts
RUN npm run build

WORKDIR /
COPY maestro ./maestro
COPY scripts/ ./maestro/scripts/

WORKDIR /maestro

# Same sequence as scripts/npm-install-with-native.sh: plain npm install runs node-gyp on @u4/opencv4nodejs too early.
# No package-lock.json in repo today — use install (switch to `npm ci` once a lockfile is committed).
RUN npm install --no-audit --no-fund --ignore-scripts

RUN npm rebuild bcrypt canvas sharp --foreground-scripts

RUN chmod +x scripts/rebuild-opencv4nodejs.sh \
    && npm run rebuild:opencv4nodejs \
    && test -n "$(find node_modules/@u4/opencv4nodejs/build -name opencv4nodejs.node -print -quit)"

EXPOSE 81

CMD ["npm", "run", "api"]
