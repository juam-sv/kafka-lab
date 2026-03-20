FROM nginx:alpine

# Upgrade packages to fix vulnerabilities (like CVE-2026-25646 in libpng)
RUN apk update && apk upgrade && \
    touch /var/run/nginx.pid && \
    chown -R nginx:nginx /var/run/nginx.pid /var/cache/nginx /var/log/nginx /etc/nginx/conf.d

COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY index.html /usr/share/nginx/html/index.html

# Ensure the nginx user can read the static files
RUN chown -R nginx:nginx /usr/share/nginx/html

USER nginx

EXPOSE 8080

