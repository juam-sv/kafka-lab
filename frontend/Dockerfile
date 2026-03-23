FROM node:22-alpine AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY . .
RUN npm run build

FROM nginx:alpine

# Upgrade packages to fix vulnerabilities (like CVE-2026-25646 in libpng)
RUN apk update && apk upgrade && \
    touch /var/run/nginx.pid && \
    chown -R nginx:nginx /var/run/nginx.pid /var/cache/nginx /var/log/nginx /etc/nginx/conf.d

COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/dist /usr/share/nginx/html

# Ensure the nginx user can read the static files
RUN chown -R nginx:nginx /usr/share/nginx/html

USER nginx

EXPOSE 8080
