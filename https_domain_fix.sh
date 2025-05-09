#!/bin/sh

FILE="/var/www/html/wp/wp-config.php"
DIR="/var/www/html/wp"
CODE="if (isset(\$_SERVER['HTTP_X_FORWARDED_PROTO']) && \$_SERVER['HTTP_X_FORWARDED_PROTO'] === 'https') {\n    \$_SERVER['HTTPS'] = 'on';\n}"

# Sprawdź, czy plik istnieje
if [ ! -f "$FILE" ]; then
  echo "Plik $FILE nie istnieje."
  exit 1
fi

# Sprawdź, czy kod już istnieje
if grep -q "HTTP_X_FORWARDED_PROTO" "$FILE"; then
  echo "Kod już istnieje w $FILE."
else
  # Dodaj kod po <?php
  awk -v insert="$CODE" '
    NR==1 && $0 ~ /<\?php/ {
      print;
      print insert;
      next
    }
    { print }
  ' "$FILE" > "${FILE}.tmp" && mv "${FILE}.tmp" "$FILE"
  echo "Kod został dodany do $FILE."
fi

# Zmień właściciela katalogu
sudo chown -R www-data:www-data "$DIR"
echo "Zmieniono właściciela katalogu $DIR na www-data:www-data."
