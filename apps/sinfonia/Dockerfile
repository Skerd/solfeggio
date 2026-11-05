# syntax=docker/dockerfile:1
# Build from the deploy folder (must contain armonia/, sinfonia/ and maestro/ for its module manifest):
#   docker build -f apps/sinfonia/Dockerfile \
#     --build-arg VITE_SINFONIA_APP=<appId> \
#     -t arpeggio-frontend-<appId>:latest deploy/
#
# Each client is a separate SPA at `/`. Vite app id ARG is declared after npm
# install so core/public/dyeus share cached dependency layers.

FROM node:22-alpine AS build

# Large Vite/Rollup graphs (15k+ modules) exceed Node's default ~2 GiB heap during chunk rendering.
ENV NODE_OPTIONS="--max-old-space-size=6144"

# Same npm 10.x / vitest 4 arborist crash as maestro. Lockfile + --legacy-peer-deps.
WORKDIR /armonia
COPY armonia/package.json armonia/package-lock.json ./
RUN --mount=type=cache,target=/root/.npm npm i --no-audit --no-fund --legacy-peer-deps
COPY armonia ./
# Deploy gate (D07/D08): `build` type-checks armonia; its tests must pass too.
RUN npm run build && npx vitest run

# The module manifest lives in maestro core (D01a); `VITE_ENABLED_MODULES` resolves dependencies from it.
COPY maestro/modules/core/modules.manifest.json /maestro/modules/core/modules.manifest.json

WORKDIR /sinfonia
COPY sinfonia/package.json ./
RUN --mount=type=cache,target=/root/.npm npm install --legacy-peer-deps --no-audit --no-fund
COPY sinfonia ./

# Deploy gate (D07/D08): the modules assembled for this instance must type-check and pass their tests, or no image is
# built. Before the app ARG, so every app image of one deploy shares this layer and it runs once.
RUN npm run typecheck && npx vitest run

ARG VITE_SINFONIA_APP=core
ENV VITE_SINFONIA_APP=$VITE_SINFONIA_APP
# Portal only: the zone whose apex and company sites share one session cookie.
ARG VITE_PORTAL_ROOT_DOMAIN=
ENV VITE_PORTAL_ROOT_DOMAIN=$VITE_PORTAL_ROOT_DOMAIN

RUN npm run build

FROM nginx:1.27-alpine

RUN rm -rf /usr/share/nginx/html/* /etc/nginx/conf.d/default.conf

COPY --from=build /sinfonia/dist /usr/share/nginx/html

RUN cat > /etc/nginx/conf.d/default.conf <<'EOF'
server {
    listen 80;
    server_name _;

    root /usr/share/nginx/html;
    index index.html;

    location / {
        try_files $uri $uri/ /index.html;
    }
}
EOF

EXPOSE 80

CMD ["nginx", "-g", "daemon off;"]
