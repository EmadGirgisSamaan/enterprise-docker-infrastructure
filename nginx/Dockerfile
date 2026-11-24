FROM nginxinc/nginx-unprivileged:1.27-alpine

COPY nginx.conf /etc/nginx/conf.d/default.conf

# Non-root users cannot bind ports below 1024, so NGINX listens on 8080
# inside the container. Compose maps host port 80 to it.
EXPOSE 8080
