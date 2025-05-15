#!/bin/bash
#
# Author: Rafal Masiarek <rafal@masiarek.pl>
# Modyfikacja: Dodano obsługę parametru nazwy domeny i konfigurację HTTPS

# Sprawdzenie czy podano parametr z nazwą domeny
if [ -z "$1" ]; then
    echo "Użycie: $0 nazwa_domeny.pl"
    exit 1
fi

DOMAIN="$1"
echo "Instalacja WordPress dla domeny: $DOMAIN"

# Check if you are root
[[ $EUID != 0 ]]  && { echo "Please run as root" ; exit; }

# Configuring tzdata if not exist
[[ ! -f /etc/localtime ]] && ln -fs /usr/share/zoneinfo/Europe/Warsaw /etc/localtime

# Założenie: LAMP jest już zainstalowany (Apache, MySQL, PHP)

# Instalacja wp-cli
wget -q -O /usr/local/bin/wp https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
wget -q -O /etc/bash_completion.d/wp-cli  https://raw.githubusercontent.com/wp-cli/wp-cli/master/utils/wp-completion.bash
chmod +x /usr/local/bin/wp
chmod +x /etc/bash_completion.d/wp-cli

# Utwórz folder dla WordPressa (użyj nazwy domeny w ścieżce)
wordpress_folder="/var/www/html/$DOMAIN"
if mkdir -p "$wordpress_folder"; then
    chown www-data:www-data "$wordpress_folder"
fi

cd "$wordpress_folder" || { echo "Nie można utworzyć katalogu"; exit; }

if ! /usr/local/bin/wp core is-installed --allow-root 2>/dev/null; then
    # Generyczna baza danych
    # https://bash.0x1fff.com/polecenia_wbudowane/polecenie_readonly.html
    readonly DB=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 12 | head -n 1)
    readonly DBPASS=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 32 | head -n 1)
    readonly Q1="CREATE DATABASE IF NOT EXISTS wp_$DB;"
    readonly Q2="GRANT ALL ON wp_$DB.* TO 'wp_$DB'@'localhost' IDENTIFIED BY '$DBPASS';"
    readonly Q3="FLUSH PRIVILEGES;"
    readonly SQL="$Q1$Q2$Q3"
    mysql -uroot -e "$SQL"
    
    # Instalacja wordpressa z uzyciem wp-cli
    # FIX: https://github.com/wp-cli/core-command/issues/30#issuecomment-323069641
    WP_CLI_CACHE_DIR=/dev/null /usr/local/bin/wp \
                core \
                download \
                --allow-root \
                --locale=pl_PL
    
    /usr/local/bin/wp \
                config \
                create \
                --allow-root \
                --dbname=wp_"$DB" \
                --dbuser=wp_"$DB" \
                --dbpass="$DBPASS" \
                --locale=pl_PL
    
    # Dodanie konfiguracji HTTPS do wp-config.php
    WP_CONFIG_PATH="$wordpress_folder/wp-config.php"
    
    # Bezpieczniejszy sposób dodania konfiguracji SSL - używamy tymczasowego pliku
    SSL_CODE="// BEGIN Cloudflare Flexible SSL Fix
if (isset(\\\$_SERVER['HTTP_X_FORWARDED_PROTO']) && strpos(\\\$_SERVER['HTTP_X_FORWARDED_PROTO'], 'https') !== false) {
    \\\$_SERVER['HTTPS'] = 'on';
} else if (isset(\\\$_SERVER['HTTP_CF_VISITOR']) && strpos(\\\$_SERVER['HTTP_CF_VISITOR'], 'https') !== false) {
    \\\$_SERVER['HTTPS'] = 'on';
}
// END Cloudflare Flexible SSL Fix"

    # Dodajemy kod przed linią "That's all, stop editing! Happy publishing."
    awk -v ssl="$SSL_CODE" '
    /That.s all, stop editing/ { print ssl; }
    { print }
    ' "$WP_CONFIG_PATH" > "$WP_CONFIG_PATH.tmp" && mv "$WP_CONFIG_PATH.tmp" "$WP_CONFIG_PATH"
    
    # Sprawdź czy kod został dodany
    if grep -q "BEGIN Cloudflare Flexible SSL Fix" "$WP_CONFIG_PATH"; then
        echo "Kod obsługi Cloudflare SSL został dodany do wp-config.php"
    else
        echo "UWAGA: Dodanie kodu SSL nie powiodło się. Należy dodać go ręcznie."
    fi
    
    # nadawanie uprawnien na pliki
    find . -exec chown www-data:www-data {} \;
    
    # Tworzenie virtualhost dla domeny
    cat > "/etc/apache2/sites-available/$DOMAIN.conf" << EOF
<VirtualHost *:80>
    ServerName $DOMAIN
    ServerAlias www.$DOMAIN
    DocumentRoot $wordpress_folder
    <Directory $wordpress_folder>
        Options FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
    ErrorLog \${APACHE_LOG_DIR}/$DOMAIN-error.log
    CustomLog \${APACHE_LOG_DIR}/$DOMAIN-access.log combined
</VirtualHost>
EOF
    
    # Aktywacja virtualhost i restart Apache
    a2ensite "$DOMAIN.conf"
    apache2ctl -t && apache2ctl graceful
    
    echo "WordPress został zainstalowany dla domeny $DOMAIN"
    echo "Ścieżka instalacji: $wordpress_folder"
    echo "Nazwa bazy danych: wp_$DB"
    echo "Użytkownik bazy danych: wp_$DB"
    echo "Hasło bazy danych: $DBPASS"
    echo "Kontynuuj konfigurację WordPress przez przeglądarkę pod adresem: http://$DOMAIN"
else
    echo -e "Istnieje juz wordpress pod sciezka $wordpress_folder automatyczna instalacja nie jest możliwa.\nJesli to nieuzywan
y wordpress usun go i ponow skrypt albo zainstaluj wordpressa recznie pod inna sciezka.";
    exit 9
fi