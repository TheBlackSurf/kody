#!/bin/sh

FILE="/var/www/html/wp/wp-config.php"
CODE="if (isset(\$_SERVER['HTTP_X_FORWARDED_PROTO']) && \$_SERVER['HTTP_X_FORWARDED_PROTO'] === 'https') {\n    \$_SERVER['HTTPS'] = 'on';\n}"

# Sprawdź, czy plik istnieje
if [ ! -f "$FILE" ]; then
  echo "Plik $FILE nie istnieje."
  exit 1
fi

# Sprawdź, czy kod już istnieje
if grep -q "HTTP_X_FORWARDED_PROTO" "$FILE"; then
  echo "Kod już istnieje w $FILE."
  exit 0
fi

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
