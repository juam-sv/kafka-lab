FROM nginx:alpine

# Use the existing nginx user and group
# But ensure permissions are correct for common nginx directories
RUN touch /var/run/nginx.pid && \
    chown -R nginx:nginx /var/run/nginx.pid /var/cache/nginx /var/log/nginx /etc/nginx/conf.d

COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY index.html /usr/share/nginx/html/index.html

# Ensure the nginx user can read the static files
RUN chown -R nginx:nginx /usr/share/nginx/html

USER nginx

EXPOSE 8080
