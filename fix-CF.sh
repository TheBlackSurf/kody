#!/bin/sh

WP_CONFIG="/var/www/html/wp/wp-config.php"
SSL_FIX_START="// BEGIN Cloudflare Flexible SSL Fix"
SSL_FIX_END="// END Cloudflare Flexible SSL Fix"

SSL_FIX_CODE="$SSL_FIX_START
if (isset(\$_SERVER['HTTP_X_FORWARDED_PROTO']) && strpos(\$_SERVER['HTTP_X_FORWARDED_PROTO'], 'https') !== false) {
    \$_SERVER['HTTPS'] = 'on';
} else if (isset(\$_SERVER['HTTP_CF_VISITOR']) && strpos(\$_SERVER['HTTP_CF_VISITOR'], 'https') !== false) {
    \$_SERVER['HTTPS'] = 'on';
}
$SSL_FIX_END"

# Sprawdź czy kod już istnieje
if grep -q "$SSL_FIX_START" "$WP_CONFIG"; then
    echo "Kod Cloudflare Flexible SSL Fix już istnieje w $WP_CONFIG — nic nie zmieniono."
else
    # Wstaw kod przed linią: "/* That's all, stop editing! Happy publishing. */"
    if grep -q "/* That's all, stop editing! Happy publishing. */" "$WP_CONFIG"; then
        sed -i "/\/\* That's all, stop editing! Happy publishing. \*\//i\\
$SSL_FIX_CODE\\
" "$WP_CONFIG"
        echo "Kod dodany pomyślnie do $WP_CONFIG."
    else
        echo "Nie znaleziono miejsca wstawienia w $WP_CONFIG. Operacja przerwana."
        exit 1
    fi
fi
