# Build from the deploy folder (must contain armonia/ and sinfonia/):
#   docker build -f apps/sinfonia/Dockerfile -t arpeggio-frontend:latest deploy/
#
# API and WebSocket routing are handled by the nginx gateway cluster.
# This image only serves the built SPA static assets.

FROM node:22-alpine AS build

WORKDIR /armonia

COPY armonia ./

RUN npm i

RUN npm run build

WORKDIR /sinfonia

COPY sinfonia ./

WORKDIR /sinfonia

RUN npm install --legacy-peer-deps

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
