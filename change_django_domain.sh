#!/bin/bash

# Skrypt do zmiany domeny w aplikacji Django i konfiguracji Nginx
# Dynamicznie wykrywa obecną domenę.

# --- Konfiguracja ---
DJANGO_APP_DIR="/var/www/django/app"
SETTINGS_FILE="${DJANGO_APP_DIR}/settings.py"
NGINX_CONF="/etc/nginx/sites-available/django.conf"
NGINX_SERVICE="nginx.service"
GUNICORN_SERVICE="gunicorn_django.service"
# --------------------

# Sprawdź, czy podano dokładnie jeden argument
if [ "$#" -ne 1 ]; then
    echo "Użycie: $0 nowa_domena.pl"
    echo "Przykład: $0 nowadomena.pl"
    exit 1
fi

NEW_DOMAIN="$1"

# --- Sprawdzenie istnienia plików ---
if [ ! -f "${SETTINGS_FILE}" ]; then
    echo "Błąd: Plik settings.py nie znaleziono pod ścieżką ${SETTINGS_FILE}"
    exit 1
fi

if [ ! -f "${NGINX_CONF}" ]; then
    echo "Błąd: Plik konfiguracyjny Nginx nie znaleziono pod ścieżką ${NGINX_CONF}"
    exit 1
fi

# --- Znajdź bieżącą domenę z settings.py ---
echo "Wykrywanie bieżącej domeny z ${SETTINGS_FILE}..."
# Używamy grep do znalezienia linii ALLOWED_HOSTS
# head -n 1 pobiera tylko pierwszą pasującą linię
# sed -E używa rozszerzonych wyrażeń regularnych
# s/.*\[ *'([^']+)'.*/\1/ - wzorzec szuka '[ *' (dowolna liczba spacji, apostrof),
#                           następnie przechwytuje w grupie 1 (([^']+)) jeden lub więcej znaków nie będących apostrofem (to nasza domena),
#                           a na końcu szuka "'" (apostrof) i reszty linii.
#                           Całość zamienia na tylko to, co zostało przechwycone w grupie 1 (\1).
CURRENT_DOMAIN=$(grep "ALLOWED_HOSTS" "${SETTINGS_FILE}" | head -n 1 | sed -E "s/.*\[ *'([^']+)'.*/\1/")

if [ -z "$CURRENT_DOMAIN" ]; then
    echo "Błąd: Nie udało się odnaleźć lub wyodrębnić bieżącej domeny z linii ALLOWED_HOSTS w ${SETTINGS_FILE}."
    echo "Upewnij się, że linia ALLOWED_HOSTS istnieje i ma format np. ALLOWED_HOSTS = ['domena.pl'] lub ALLOWED_HOSTS = ['domena.pl', 'www.domena.pl']"
    exit 1
fi

echo "Wykryto bieżącą domenę: '${CURRENT_DOMAIN}'"
echo "Zmiana na nową domenę: '${NEW_DOMAIN}'..."

# --- Zmiana w settings.py (ALLOWED_HOSTS) ---
echo "Aktualizacja ${SETTINGS_FILE}..."
# Zamieniamy wykrytą bieżącą domenę na nową domenę
# Flaga -i modyfikuje plik w miejscu
# Flaga g zapewnia zamianę wszystkich wystąpień w linii (np. w przypadku 'domena.pl', 'www.domena.pl')
sed -i "s/${CURRENT_DOMAIN}/${NEW_DOMAIN}/g" "${SETTINGS_FILE}"
if [ $? -ne 0 ]; then
    echo "Błąd podczas aktualizacji ${SETTINGS_FILE}."
    exit 1
fi
echo "${SETTINGS_FILE} zaktualizowany."

# --- Zmiana w konfiguracji Nginx (server_name) ---
echo "Aktualizacja ${NGINX_CONF}..."
# Zamieniamy wykrytą bieżącą domenę. To powinno poprawnie zaktualizować zarówno 'domena.pl' jak i 'www.domena.pl' w linii server_name.
sed -i "s/${CURRENT_DOMAIN}/${NEW_DOMAIN}/g" "${NGINX_CONF}"
if [ $? -ne 0 ]; then
    echo "Błąd podczas aktualizacji ${NGINX_CONF}."
    exit 1
fi
echo "${NGINX_CONF} zaktualizowany."

# --- Restart usług ---
echo "Restartowanie usług ${NGINX_SERVICE} i ${GUNICORN_SERVICE}..."

systemctl restart "${NGINX_SERVICE}"
if [ $? -ne 0 ]; then
    echo "Błąd podczas restartu usługi ${NGINX_SERVICE}."
    echo "Proszę zrestartować ręcznie: systemctl restart ${NGINX_SERVICE}"
    exit 1
fi
echo "Usługa ${NGINX_SERVICE} zrestartowana."

systemctl restart "${GUNICORN_SERVICE}"
if [ $? -ne 0 ]; then
    echo "Błąd podczas restartu usługi ${GUNICORN_SERVICE}."
    echo "Proszę zrestartować ręcznie: systemctl restart ${GUNICORN_SERVICE}"
    exit 1
fi
echo "Usługa ${GUNICORN_SERVICE} zrestartowana."

echo "Zmiana domeny zakończona sukcesem na ${NEW_DOMAIN}."

exit 0