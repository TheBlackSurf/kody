#!/bin/bash

# Katalog docelowy
WP_DIR="/var/www/html/wp"

# Ustaw właściciela rekursywnie
echo "Ustawianie właściciela na www-data:www-data w: $WP_DIR"
chown -R www-data:www-data "$WP_DIR"

# Ustawienia praw katalogów i plików
echo "Ustawianie praw do katalogów na 755..."
find "$WP_DIR" -type d -exec chmod 755 {} \;

echo "Ustawianie praw do plików na 644..."
find "$WP_DIR" -type f -exec chmod 644 {} \;

# Obsługa wyjątków – jeśli katalog cache istnieje i jest rootem
CACHE_DIR="$WP_DIR/wp-content/cache"
if [ -d "$CACHE_DIR" ]; then
    echo "Naprawianie właściciela cache/ na www-data"
    chown -R www-data:www-data "$CACHE_DIR"
    find "$CACHE_DIR" -type d -exec chmod 755 {} \;
    find "$CACHE_DIR" -type f -exec chmod 644 {} \;
fi

echo "Uprawnienia poprawione."
