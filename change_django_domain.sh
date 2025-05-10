#!/bin/bash

# Skrypt do zmiany domeny w aplikacji Django i konfiguracji Nginx
# Dynamicznie wykrywa obecną domenę i zarządza CSRF_TRUSTED_ORIGINS.

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
CURRENT_DOMAIN_LINE=$(grep "ALLOWED_HOSTS" "${SETTINGS_FILE}" | head -n 1)
if [ -z "$CURRENT_DOMAIN_LINE" ]; then
    echo "Błąd: Linia ALLOWED_HOSTS nie została znaleziona w ${SETTINGS_FILE}."
    exit 1
fi

CURRENT_DOMAIN=$(echo "$CURRENT_DOMAIN_LINE" | sed -E "s/.*\[[[:space:]]*'([^']+)'.*/\1/")

if [ -z "$CURRENT_DOMAIN" ] || [[ "$CURRENT_DOMAIN" == "$CURRENT_DOMAIN_LINE" ]]; then # Jeśli sed nie zmienił linii, to wzorzec nie pasował
    echo "Błąd: Nie udało się wyodrębnić bieżącej domeny z linii ALLOWED_HOSTS: ${CURRENT_DOMAIN_LINE}"
    echo "Upewnij się, że linia ALLOWED_HOSTS istnieje i ma format np. ALLOWED_HOSTS = ['domena.pl']"
    exit 1
fi

echo "Wykryto bieżącą domenę (pierwszą z ALLOWED_HOSTS): '${CURRENT_DOMAIN}'"
echo "Zmiana na nową domenę: '${NEW_DOMAIN}'..."

# --- Zmiana w settings.py (ALLOWED_HOSTS) ---
echo "Aktualizacja ALLOWED_HOSTS w ${SETTINGS_FILE}..."
cp "${SETTINGS_FILE}" "${SETTINGS_FILE}.bak_allowedhosts"
# Zamieniamy wykrytą bieżącą domenę na nową domenę.
# To jest ogólna zamiana, która może wpłynąć na inne części pliku, jeśli CURRENT_DOMAIN tam występuje.
# Dla większej precyzji można by ograniczyć do linii ALLOWED_HOSTS i konkretnego formatu.
sed -i "s/${CURRENT_DOMAIN}/${NEW_DOMAIN}/g" "${SETTINGS_FILE}"
if [ $? -ne 0 ]; then
    echo "Błąd podczas aktualizacji ALLOWED_HOSTS w ${SETTINGS_FILE}."
    mv "${SETTINGS_FILE}.bak_allowedhosts" "${SETTINGS_FILE}" # Przywróć
    exit 1
fi
# Weryfikacja, czy zmiana nastąpiła (prosta, dla nowej domeny w apostrofach)
if grep -q "'${NEW_DOMAIN}'" "${SETTINGS_FILE}"; then
    echo "ALLOWED_HOSTS w ${SETTINGS_FILE} zaktualizowane."
    rm -f "${SETTINGS_FILE}.bak_allowedhosts" # Usuń kopię zapasową
else
    echo "Ostrzeżenie: ALLOWED_HOSTS mogło nie zostać poprawnie zaktualizowane. Sprawdź ręcznie ${SETTINGS_FILE}."
    echo "Przywracanie z ${SETTINGS_FILE}.bak_allowedhosts"
    mv "${SETTINGS_FILE}.bak_allowedhosts" "${SETTINGS_FILE}" # Przywróć
    exit 1
fi


# --- Zmiana w settings.py (CSRF_TRUSTED_ORIGINS) ---
echo "Aktualizacja CSRF_TRUSTED_ORIGINS w ${SETTINGS_FILE}..."
# Sprawdź, czy linia CSRF_TRUSTED_ORIGINS już istnieje (niezakomentowana, z ewentualnymi wcięciami)
if grep -qE "^[[:space:]]*CSRF_TRUSTED_ORIGINS[[:space:]]*=" "${SETTINGS_FILE}"; then
    echo "Znaleziono istniejącą konfigurację CSRF_TRUSTED_ORIGINS. Aktualizowanie..."
    cp "${SETTINGS_FILE}" "${SETTINGS_FILE}.bak_csrf"
    # Zaktualizuj pierwszą domenę URL (https://...) w cudzysłowie w linii CSRF_TRUSTED_ORIGINS
    # Używamy # jako separatora w sed, aby uniknąć konfliktu z https://
    # [^']* pasuje do wszystkiego wewnątrz apostrofów
    sed -i "/^[[:space:]]*CSRF_TRUSTED_ORIGINS[[:space:]]*=/s#'https://[^']*'#'https://${NEW_DOMAIN}'#1" "${SETTINGS_FILE}"
    if [ $? -ne 0 ]; then
        echo "Błąd: Nie udało się wykonać komendy sed do aktualizacji CSRF_TRUSTED_ORIGINS."
        echo "Sprawdź ręcznie ${SETTINGS_FILE}. Przywracanie z ${SETTINGS_FILE}.bak_csrf"
        mv "${SETTINGS_FILE}.bak_csrf" "${SETTINGS_FILE}"
        # Można rozważyć exit 1, jeśli to krytyczne
    else
        # Sprawdź, czy zmiana faktycznie nastąpiła
        if grep -q "'https://${NEW_DOMAIN}'" "${SETTINGS_FILE}"; then
             echo "CSRF_TRUSTED_ORIGINS pomyślnie zaktualizowane."
             rm -f "${SETTINGS_FILE}.bak_csrf"
        else
             echo "Ostrzeżenie: CSRF_TRUSTED_ORIGINS znaleziono, ale mogło nie zostać poprawnie zaktualizowane."
             echo "Oczekiwano zmiany na 'https://${NEW_DOMAIN}', ale nie znaleziono jej po operacji."
             echo "Możliwe, że format w pliku jest inny lub domena do podmiany nie pasowała."
             echo "Sprawdź ręcznie ${SETTINGS_FILE}. Kopia zapasowa w ${SETTINGS_FILE}.bak_csrf"
             # Nie przywracamy automatycznie, aby umożliwić inspekcję
        fi
    fi
else
    echo "CSRF_TRUSTED_ORIGINS nie znaleziono lub jest zakomentowane. Dodawanie nowej konfiguracji..."
    cp "${SETTINGS_FILE}" "${SETTINGS_FILE}.bak_csrf_add"
    # Dodaj CSRF_TRUSTED_ORIGINS po linii zawierającej ALLOWED_HOSTS (niezakomentowanej)
    awk -v new_csrf_line="CSRF_TRUSTED_ORIGINS = ['https://${NEW_DOMAIN}']" '
    /^[[:space:]]*ALLOWED_HOSTS[[:space:]]*=/ {
        print; # Drukuj linię ALLOWED_HOSTS
        print new_csrf_line; # Drukuj nową linię CSRF zaraz po niej
        next # Przejdź do następnej linii wejściowej
    }
    { print } # Drukuj wszystkie inne linie
    ' "${SETTINGS_FILE}.bak_csrf_add" > "${SETTINGS_FILE}"

    if [ $? -ne 0 ]; then
        echo "Błąd: Nie udało się dodać CSRF_TRUSTED_ORIGINS do ${SETTINGS_FILE} (błąd awk)."
        mv "${SETTINGS_FILE}.bak_csrf_add" "${SETTINGS_FILE}" # Przywróć oryginał
        # Można rozważyć exit 1
    else
        # Sprawdź, czy linia została dodana
        if grep -q "CSRF_TRUSTED_ORIGINS = \['https://${NEW_DOMAIN}'\]" "${SETTINGS_FILE}"; then
            echo "Dodano CSRF_TRUSTED_ORIGINS = ['https://${NEW_DOMAIN}'] do ${SETTINGS_FILE}."
            rm -f "${SETTINGS_FILE}.bak_csrf_add" # Usuń kopię zapasową
        else
            echo "Błąd: Nie udało się zweryfikować dodania CSRF_TRUSTED_ORIGINS (grep nie znalazł). Sprawdź ręcznie ${SETTINGS_FILE}."
            mv "${SETTINGS_FILE}.bak_csrf_add" "${SETTINGS_FILE}" # Przywróć oryginał
            # Można rozważyć exit 1
        fi
    fi
fi

# --- Zmiana w konfiguracji Nginx (server_name) ---
echo "Aktualizacja server_name w ${NGINX_CONF}..."
cp "${NGINX_CONF}" "${NGINX_CONF}.bak_nginx"
# Zamieniamy wykrytą bieżącą domenę.
sed -i "s/${CURRENT_DOMAIN}/${NEW_DOMAIN}/g" "${NGINX_CONF}"
if [ $? -ne 0 ]; then
    echo "Błąd podczas aktualizacji ${NGINX_CONF}."
    mv "${NGINX_CONF}.bak_nginx" "${NGINX_CONF}"
    exit 1
fi
# Prosta weryfikacja
if grep -q "${NEW_DOMAIN}" "${NGINX_CONF}"; then
    echo "${NGINX_CONF} zaktualizowany."
    rm -f "${NGINX_CONF}.bak_nginx"
else
    echo "Ostrzeżenie: ${NGINX_CONF} mogło nie zostać poprawnie zaktualizowane. Sprawdź ręcznie."
    mv "${NGINX_CONF}.bak_nginx" "${NGINX_CONF}"
    exit 1
fi


# --- Restart usług ---
echo "Restartowanie usług ${NGINX_SERVICE} i ${GUNICORN_SERVICE}..."

echo "Testowanie konfiguracji Nginx..."
nginx -t
if [ $? -ne 0 ]; then
    echo "Błąd: Konfiguracja Nginx jest niepoprawna po zmianach! Nie restartuję usług."
    echo "Przywracanie oryginalnego pliku ${NGINX_CONF} z ${NGINX_CONF}.bak_nginx (jeśli istnieje i jest to jedyna zmiana Nginx)"
    # Uwaga: jeśli były inne zmiany w Nginx, to może nie być poprawne.
    # Na razie zakładamy, że tylko server_name było zmieniane przez ten skrypt.
    # Jeśli .bak_nginx nie istnieje, to znaczy, że błąd sed wystąpił wcześniej.
    if [ -f "${NGINX_CONF}.bak_nginx" ]; then # Sprawdź, czy kopia zapasowa istnieje
         mv "${NGINX_CONF}.bak_nginx" "${NGINX_CONF}"
         echo "Plik ${NGINX_CONF} przywrócony. Sprawdź konfigurację Nginx ręcznie."
    else
         echo "Nie znaleziono kopii zapasowej ${NGINX_CONF}.bak_nginx do przywrócenia."
    fi
    echo "Przywracanie oryginalnego pliku ${SETTINGS_FILE} (jeśli były zmiany CSRF/ALLOWED_HOSTS)"
    # To jest bardziej skomplikowane, bo mogły być dwie operacje na settings.py
    # Najbezpieczniej jest poinformować użytkownika o ręcznym sprawdzeniu.
    echo "Sprawdź ręcznie ${SETTINGS_FILE} i przywróć z kopii .bak_allowedhosts lub .bak_csrf* jeśli to konieczne."
    exit 1
fi
echo "Konfiguracja Nginx poprawna."

systemctl restart "${NGINX_SERVICE}"
if [ $? -ne 0 ]; then
    echo "Błąd podczas restartu usługi ${NGINX_SERVICE}."
    echo "Proszę zrestartować ręcznie: systemctl restart ${NGINX_SERVICE}"
    # Rozważ przywrócenie konfiguracji Nginx, jeśli restart się nie powiedzie
    exit 1
fi
echo "Usługa ${NGINX_SERVICE} zrestartowana."

systemctl restart "${GUNICORN_SERVICE}"
if [ $? -ne 0 ]; then
    echo "Błąd podczas restartu usługi ${GUNICORN_SERVICE}."
    echo "Proszę zrestartować ręcznie: systemctl restart ${GUNICORN_SERVICE}"
    # Rozważ przywrócenie settings.py, jeśli Gunicorn nie startuje z powodu błędów Django
    exit 1
fi
echo "Usługa ${GUNICORN_SERVICE} zrestartowana."

echo "Zmiana domeny zakończona sukcesem na ${NEW_DOMAIN}."

exit 0