ARG NGINX_IMAGE=nginx:stable-bookworm
FROM ${NGINX_IMAGE}

# Install certbot and openssl
RUN apt-get update \
 && apt-get install -y --no-install-recommends certbot openssl apache2-utils \
 && rm -rf /var/lib/apt/lists/*

RUN rm -f /etc/nginx/conf.d/default.conf

# Copy nginx configurations
COPY nginx/nginx.conf        /etc/nginx/nginx.conf
COPY nginx/includes/acme.conf /etc/nginx/includes/acme.conf

# Entrypoint + parsing library
COPY entrypoint.sh  /entrypoint.sh
COPY lib/parse.sh   /lib/parse.sh
RUN chmod +x /entrypoint.sh

# Runtime directories
RUN mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled /var/www/certbot

# Config a user for web. Pass the username and password by "--build-arg"
ARG NGINX_USER=nginx_user
ARG NGINX_PASS=nginx_pass
RUN htpasswd -cb /etc/nginx/.htpasswd ${NGINX_USER} ${NGINX_PASS} && \
    chmod 644 /etc/nginx/.htpasswd

ENTRYPOINT ["/entrypoint.sh"]
