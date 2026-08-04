FROM nginx:1.27-bookworm

# Install certbot
RUN apt-get update \
 && apt-get install -y --no-install-recommends certbot \
 && rm -rf /var/lib/apt/lists/*

# nginx configuration
COPY nginx/nginx.conf        /etc/nginx/nginx.conf
COPY nginx/includes/acme.conf /etc/nginx/includes/acme.conf

# Entrypoint + parsing library
COPY entrypoint.sh  /entrypoint.sh
COPY lib/parse.sh   /lib/parse.sh
RUN chmod +x /entrypoint.sh

# Runtime directories
RUN mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled /var/www/certbot

ENTRYPOINT ["/entrypoint.sh"]
