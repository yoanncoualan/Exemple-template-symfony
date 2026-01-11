# Dockerfile pour Symfony 8.0 sur Render.com
FROM php:8.4-fpm-alpine AS base

# Installation des dépendances système et extensions PHP
RUN apk add --no-cache \
    nginx \
    supervisor \
    postgresql-dev \
    libzip-dev \
    libpng-dev \
    libjpeg-turbo-dev \
    freetype-dev \
    icu-dev \
    linux-headers \
    bash \
    && docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install -j$(nproc) \
    pdo \
    pdo_pgsql \
    intl \
    zip \
    opcache \
    gd

# Configuration PHP pour production
RUN { \
    echo 'opcache.enable=1'; \
    echo 'opcache.memory_consumption=256'; \
    echo 'opcache.interned_strings_buffer=16'; \
    echo 'opcache.max_accelerated_files=20000'; \
    echo 'opcache.validate_timestamps=0'; \
    echo 'realpath_cache_size=4096K'; \
    echo 'realpath_cache_ttl=600'; \
    } > /usr/local/etc/php/conf.d/opcache.ini

# Configuration PHP générale
RUN { \
    echo 'memory_limit=512M'; \
    echo 'upload_max_filesize=50M'; \
    echo 'post_max_size=50M'; \
    echo 'max_execution_time=300'; \
    echo 'date.timezone=Europe/Paris'; \
    } > /usr/local/etc/php/conf.d/symfony.ini

# Installation de Composer
COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

WORKDIR /app

# Stage pour les dépendances
FROM base AS dependencies

# Copie des fichiers de dépendances
COPY composer.json composer.lock symfony.lock ./

# Installation des dépendances PHP (sans dev)
RUN composer install --no-dev --no-scripts --no-autoloader --prefer-dist --optimize-autoloader

# Stage final
FROM base AS final

# Copie des dépendances depuis le stage précédent
COPY --from=dependencies /app/vendor ./vendor

# Copie de tous les fichiers de l'application
COPY . .

# Finalisation de l'autoloader optimisé
RUN composer dump-autoload --no-dev --classmap-authoritative

# Configuration Nginx
RUN mkdir -p /etc/nginx/http.d && \
    rm -f /etc/nginx/http.d/default.conf

COPY <<'EOF' /etc/nginx/http.d/symfony.conf
server {
    listen 10000;
    server_name _;
    root /app/public;

    location / {
        try_files $uri /index.php$is_args$args;
    }

    location ~ ^/index\.php(/|$) {
        fastcgi_pass 127.0.0.1:9000;
        fastcgi_split_path_info ^(.+\.php)(/.*)$;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME $realpath_root$fastcgi_script_name;
        fastcgi_param DOCUMENT_ROOT $realpath_root;
        internal;
    }

    location ~ \.php$ {
        return 404;
    }

    client_max_body_size 50M;
}
EOF

# Configuration Supervisor
COPY <<'EOF' /etc/supervisor/conf.d/supervisord.conf
[supervisord]
nodaemon=true
user=root
logfile=/dev/stdout
logfile_maxbytes=0
pidfile=/var/run/supervisord.pid

[program:php-fpm]
command=php-fpm --nodaemonize
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
autorestart=true

[program:nginx]
command=nginx -g 'daemon off;'
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
autorestart=true
EOF

# Script d'entrée
COPY <<'EOF' /usr/local/bin/docker-entrypoint.sh
#!/bin/sh
set -e

echo "Starting Symfony application..."

# Attendre que la base de données soit prête
until php bin/console dbal:run-sql "SELECT 1" > /dev/null 2>&1; do
    echo "Waiting for database..."
    sleep 2
done

echo "Database is ready!"

# Exécuter les migrations
php bin/console doctrine:migrations:migrate --no-interaction --allow-no-migration || true

# Vider le cache
php bin/console cache:clear --no-warmup
php bin/console cache:warmup

# Installer les assets
php bin/console assets:install --no-interaction
php bin/console importmap:install

# Créer les répertoires nécessaires
mkdir -p var/cache var/log
chmod -R 777 var

exec "$@"
EOF

RUN chmod +x /usr/local/bin/docker-entrypoint.sh

# Variables d'environnement par défaut
ENV APP_ENV=prod
ENV APP_DEBUG=0

# Exposition du port (Render.com utilise le port 10000 par défaut)
EXPOSE 10000

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/conf.d/supervisord.conf"]
