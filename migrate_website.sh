#!/bin/bash

# --- Konfiguracja ---
# Ścieżka do katalogu instalacji WordPressa, do którego skrypt MA przejść
# Zmień tę ścieżkę, jeśli Twoja instalacja WordPressa jest w innym miejscu
WP_ROOT_DIR="/var/www/html/wp"

# Nazwa katalogu na backupy w wp-content (używana przez wtyczkę Izolka Migrate)
BACKUP_DIR_NAME="izolka-backups"
# Ścieżka do katalogu wp-content w docelowej instalacji
WP_CONTENT_DIR="$WP_ROOT_DIR/wp-content"
# Pełna ścieżka do katalogu backupów w docelowej instalacji
FULL_BACKUP_DIR="$WP_CONTENT_DIR/$BACKUP_DIR_NAME"

# Nazwa tymczasowego katalogu do pobierania i rozpakowywania
TEMP_DIR_NAME="izolka-migration-temp"
# Pełna ścieżka do tymczasowego katalogu (będzie utworzony w WP_ROOT_DIR)
FULL_TEMP_DIR="$WP_ROOT_DIR/$TEMP_DIR_NAME"

# Nazwa tymczasowego pliku ZIP (będzie pobierany DO TEGO KATALOGU w kawałkach)
TEMP_ZIP_FILE="backup_pobrany.zip"
# Pełna ścieżka do tymczasowego pliku ZIP
FULL_TEMP_ZIP_PATH="$FULL_TEMP_DIR/$TEMP_ZIP_FILE"


# Rozmiar kawałka do pobierania (w bajtach) - dostosuj, jeśli nadal występują problemy
CHUNK_SIZE=5242880 # 5MB - można zwiększyć lub zmniejszyć

# Opcjonalnie: Pełna ścieżka do WP-CLI, jeśli nie jest w PATH
# WP_CLI_BIN="/usr/local/bin/wp"
WP_CLI_BIN="wp" # Zakładamy, że 'wp' jest w PATH

# Flaga --allow-root dla WP-CLI - Używaj ostrożnie!
WP_CLI_FLAGS="--allow-root"


# --- Sprawdzenie argumentów ---
if [ "$#" -ne 2 ]; then
    echo "Użycie: $0 <url_strony_zrodlowej_bez_http_s> <klucz_api_izolka>"
    echo "Przykład: $0 cbmc.pl SKOPIOWANY_NOWY_KLUCZ_IZOLKA"
    exit 1
fi

SOURCE_DOMAIN="$1"
API_KEY="$2"

SOURCE_BASE_URL="https://$SOURCE_DOMAIN" # Zakładamy https dla API
TRIGGER_ENDPOINT="$SOURCE_BASE_URL/wp-json/izolka-migrate/v1/trigger"
DOWNLOAD_ENDPOINT="$SOURCE_BASE_URL/wp-json/izolka-migrate/v1/download"

# --- Przejście do katalogu docelowego WordPressa ---
echo "Przechodzenie do katalogu WordPressa docelowego: $WP_ROOT_DIR"
cd "$WP_ROOT_DIR" || { echo "Błąd: Nie można przejść do katalogu WordPressa: $WP_ROOT_DIR. Sprawdź, czy katalog istnieje i masz do niego uprawnienia."; exit 1; }
echo "Jesteś w katalogu: $(pwd)"

# --- Sprawdzenie wymaganych narzędzi ---
echo "Sprawdzanie wymaganych narzędzi..."
command -v curl >/dev/null 2>&1 || { echo >&2 "Błąd: wymagany curl nie jest zainstalowany."; exit 1; }
command -v unzip >/dev/null 2>&1 || { echo >&2 "Błąd: wymagany unzip nie jest zainstalowany."; exit 1; }
command -v jq >/dev/null 2>&1 || { echo >&2 "Błąd: wymagany jq (do parsowania JSON) nie jest zainstalowany. Zainstaluj go (np. apt-get install jq)."; exit 1; }
command -v stat >/dev/null 2>&1 || { echo >&2 "Błąd: wymagany stat (do sprawdzania rozmiaru pliku) nie jest zainstalowany."; exit 1; } # Sprawdzenie stat

# Sprawdzenie WP-CLI
if ! command -v "$WP_CLI_BIN" >/dev/null 2>&1; then
    echo >&2 "Błąd: WP-CLI ('$WP_CLI_BIN') nie jest zainstalowane lub nie ma go w PATH. Zainstaluj WP-CLI."
    exit 1
fi
# Sprawdzenie, czy można uruchomić WP-CLI z --allow-root (w bieżącym katalogu WP)
if ! "$WP_CLI_BIN" --version "$WP_CLI_FLAGS" >/dev/null 2>&1; then
    echo >&2 "Błąd: Nie można uruchomić WP-CLI z '$WP_CLI_FLAGS' w katalogu '$WP_ROOT_DIR'. Sprawdź uprawnienia lub konfigurację."
    exit 1
fi

echo "Narzędzia OK."

# --- Sprawdzenie struktury katalogu docelowego WP ---
# Sprawdzamy TERAZ, gdy już jesteśmy w katalogu docelowym
if [ ! -f "wp-config.php" ] || [ ! -d "wp-admin" ] || [ ! -d "wp-includes" ]; then
    echo "Błąd: Katalog '$WP_ROOT_DIR' nie wygląda na główny katalog instalacji WordPressa."
    echo "Brak plików/katalogów: wp-config.php, wp-admin, wp-includes."
    exit 1
fi
echo "Struktura katalogu WordPressa docelowego OK."

# --- Potwierdzenie operacji ---
echo ""
echo "!!! OSTRZEŻENIE !!!"
echo "Ten skrypt POBIERZE backup z $SOURCE_BASE_URL i CAŁKOWICIE nadpisze pliki i bazę danych"
echo "w docelowej instalacji WordPressa ($WP_ROOT_DIR)."
echo "Jest to operacja DESTRUKCYJNA i NIEODWRACALNA."
echo ""
read -r -p "Czy na pewno chcesz kontynuować? (wpisz TAK aby potwierdzić): " confirm
if [ "$confirm" != "TAK" ]; then
    echo "Operacja anulowana."
    exit 0
fi
echo ""

# --- Przygotowanie tymczasowego katalogu (TERAZ JESTEŚMY W WP_ROOT_DIR) ---
echo "Przygotowanie tymczasowego katalogu: $FULL_TEMP_DIR"
rm -rf "$FULL_TEMP_DIR" # Usuń poprzednie tymczasowe pliki
mkdir -p "$FULL_TEMP_DIR"
if [ $? -ne 0 ]; then echo "Błąd: Nie można utworzyć katalogu tymczasowego w $WP_ROOT_DIR."; exit 1; fi
echo "Katalog tymczasowy OK."

# --- Wywołanie backupu na źródle i pobranie informacji ---
echo "Wywoływanie backupu na stronie źródłowej: $TRIGGER_ENDPOINT"
# Użyj curl do wywołania POST i pobrania odpowiedzi JSON
TRIGGER_RESPONSE=$(curl -s -X POST -H "X-API-Key: $API_KEY" "$TRIGGER_ENDPOINT")
TRIGGER_HTTP_STATUS=$(echo "$TRIGGER_RESPONSE" | head -n 1 | grep -oP '(?<=HTTP/1.1 )\d+') # Spróbuj sparsować status z odpowiedzi

# Jeśli odpowiedź curl -s nie zaczyna się od HTTP/1.1 (bo nie ma np. błędów nagłówka), pobierz status inaczej
if [ -z "$TRIGGER_HTTP_STATUS" ]; then
    # Pobierz tylko status bez treści
    TRIGGER_HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST -H "X-API-Key: $API_KEY" "$TRIGGER_ENDPOINT")
    # Spróbuj ponownie pobrać treść - może tym razem będzie czysty JSON po wcześniejszym żądaniu?
    # To uproszczenie - lepsze byłoby logowanie błędu na źródle
    if [ "$TRIGGER_HTTP_STATUS" -eq 200 ]; then
         TRIGGER_RESPONSE=$(curl -s -X POST -H "X-API-Key: $API_KEY" "$TRIGGER_ENDPOINT")
    fi
fi


if [ "$TRIGGER_HTTP_STATUS" -ne 200 ]; then
    echo "Błąd: Nie udało się wywołać backupu. Status HTTP: $TRIGGER_HTTP_STATUS"
    echo "Odpowiedź serwera:"
    echo "$TRIGGER_RESPONSE"
    rm -rf "$FULL_TEMP_DIR"
    exit 1
fi
echo "Backup wywołany pomyślnie (status 200)."

# Parsuj odpowiedź JSON, aby uzyskać nazwę pliku i rozmiar
# UWAGA: Jeśli odpowiedź triggera nadal zawiera Notice/Warning przed JSON, jq zawiedzie.
# Poprzednia próba pokazała, że ten problem zniknął, co sugeruje poprawną konfigurację wp-config.php na źródle.
BACKUP_FILENAME=$(echo "$TRIGGER_RESPONSE" | jq -r '.filename')
BACKUP_FILESIZE=$(echo "$TRIGGER_RESPONSE" | jq -r '.file_size')

if [ "$BACKUP_FILENAME" == "null" ] || [ "$BACKUP_FILESIZE" == "null" ] || [ -z "$BACKUP_FILENAME" ] || [ -z "$BACKUP_FILESIZE" ]; then
    echo "Błąd: Nie udało się pobrać nazwy pliku lub rozmiaru z odpowiedzi triggera."
    echo "Sprawdź, czy odpowiedź z serwera źródłowego jest czystym JSON bez dodatkowego tekstu (np. PHP Notices)."
    echo "Odpowiedź serwera (RAW):"
    echo "$TRIGGER_RESPONSE"
    rm -rf "$FULL_TEMP_DIR"
    exit 1
fi

echo "Informacje o backupie: Plik: $BACKUP_FILENAME, Rozmiar: $BACKUP_FILESIZE bajtów."


# --- Pobieranie backupu w częściach (TERAZ JESTEŚMY W WP_ROOT_DIR) ---
echo "Pobieranie backupu w częściach z: $DOWNLOAD_ENDPOINT"
echo "Rozmiar części: $CHUNK_SIZE bajtów."

current_byte=0
# Utwórz pusty plik docelowy lub wyczyść go
> "$FULL_TEMP_ZIP_PATH"

while [ "$current_byte" -lt "$BACKUP_FILESIZE" ]; do
    start_byte="$current_byte"
    end_byte="$((current_byte + CHUNK_SIZE - 1))"

    # Upewnij się, że end_byte nie przekracza rozmiaru pliku
    if [ "$end_byte" -ge "$BACKUP_FILESIZE" ]; then
        end_byte="$((BACKUP_FILESIZE - 1))"
    fi

    # Zakres żądania dla curl
    RANGE_SPEC="$start_byte-$end_byte"

    # Prosty wskaźnik postępu
    # Upewnij się, że BACKUP_FILESIZE nie jest zerem, aby uniknąć dzielenia przez zero
    if [ "$BACKUP_FILESIZE" -gt 0 ]; then
        progress=$(( (current_byte * 100) / BACKUP_FILESIZE ))
        echo -ne "Pobieranie: ${progress}% (część $RANGE_SPEC)\r"
    else
        # Obsłuż przypadek pustego pliku
        echo -ne "Pobieranie: 0% (Plik ma rozmiar 0)\r"
        break # Wyjdź z pętli jeśli rozmiar pliku to 0
    fi


    # Użyj curl, aby pobrać zakres i DODAĆ go bezpośrednio do pliku,
    # kierując status code (-w) na stderr, które złapiemy w zmiennej.
    # --create-dirs jest na wszelki wypadek, --append dopisuje do pliku.
    # 2>&1 kieruje stderr curl na stdout skryptu, a >/dev/null ukrywa stdout curl (czyli dane pliku)
    # Nowa konstrukcja: standardowe wyjście curl (-o file) idzie do pliku, standardowe wyjście błędów (status z -w) idzie do zmiennej.
    HTTP_STATUS=$(curl -s -w "%{http_code}" -H "X-API-Key: $API_KEY" -r "$RANGE_SPEC" "$DOWNLOAD_ENDPOINT" -o "$FULL_TEMP_ZIP_PATH" --create-dirs --append 2>&1 >/dev/null)

    # Sprawdź status HTTP - oczekujemy 206 (Partial Content)
    # Przy prawidłowej obsłudze Range przez serwer, nawet ostatnia część powinna zwrócić 206.
    # Jeśli serwer nie obsługuje Range poprawnie, może zwrócić 200. Akceptujemy 200 tylko jeśli current_byte było 0 (cały plik na raz).
    # W przypadku pobierania w kawałkach, zawsze oczekujemy 206.
    if [ "$HTTP_STATUS" -ne 206 ]; then
        echo -e "\nBłąd podczas pobierania części $RANGE_SPEC. Oczekiwano statusu 206, otrzymano $HTTP_STATUS."
        echo "Przerywanie pobierania."
        rm -rf "$FULL_TEMP_DIR"
        exit 1
    fi

    # Przejdź do następnej części
    current_byte=$((end_byte + 1))

done
echo -e "\nPobieranie zakończone."

echo "Weryfikacja rozmiaru pobranego pliku..."
DOWNLOADED_SIZE=$(stat -c %s "$FULL_TEMP_ZIP_PATH" 2>/dev/null) # Użyj stat do sprawdzenia rozmiaru

if [ -z "$DOWNLOADED_SIZE" ] || [ "$DOWNLOADED_SIZE" -ne "$BACKUP_FILESIZE" ]; then
    echo "Błąd: Rozmiar pobranego pliku ($DOWNLOADED_SIZE bajtów) nie zgadza się z rozmiarem oczekiwanym ($BACKUP_FILESIZE bajtów) lub plik nie istnieje."
    rm -rf "$FULL_TEMP_DIR"
    exit 1
fi

echo "Backup pobrany pomyślnie do: $FULL_TEMP_ZIP_PATH"

# --- Rozpakowanie backupu (TERAZ JESTEŚMY W WP_ROOT_DIR, rozpakowujemy z TEMP_DIR) ---
echo "Rozpakowywanie backupu..."
# Rozpakuj do katalogu tymczasowego
unzip -o "$FULL_TEMP_ZIP_PATH" -d "$FULL_TEMP_DIR/"
if [ $? -ne 0 ]; then
    echo "Błąd: Nie udało się rozpakować pliku backupu w $FULL_TEMP_DIR."
    rm -rf "$FULL_TEMP_DIR"
    exit 1
fi
echo "Backup rozpakowany."

# --- Identyfikacja plików backupu (TERAZ JESTEŚMY W WP_ROOT_DIR) ---
# Znajdź plik SQL - zakładamy, że jest jeden SQL z patternu database_*.sql w rozpakowanym katalogu tymczasowym
SQL_FILE=$(find "$FULL_TEMP_DIR" -maxdepth 1 -name 'database_*.sql' -print -quit)

if [ -z "$SQL_FILE" ] || [ ! -f "$SQL_FILE" ]; then
    echo "Błąd: Nie znaleziono pliku bazy danych (.sql) w rozpakowanym backupie w $FULL_TEMP_DIR."
    rm -rf "$FULL_TEMP_DIR"
    exit 1
fi
echo "Znaleziono plik bazy danych: $SQL_FILE" # Drukuj pełną ścieżkę, jest w temp

# --- Migracja bazy danych (TERAZ JESTEŚMY W WP_ROOT_DIR) ---
echo "Rozpoczęcie migracji bazy danych..."

# Pobierz aktualny URL strony docelowej
NEW_URL=$("$WP_CLI_BIN" option get siteurl "$WP_CLI_FLAGS" 2>/dev/null)
if [ -z "$NEW_URL" ]; then
    echo "Błąd: Nie można pobrać adresu URL docelowej strony za pomocą WP-CLI."
    rm -rf "$FULL_TEMP_DIR"
    exit 1
fi
echo "Docelowy URL strony (nowy): $NEW_URL"

# Usunięcie istniejących tabel w bazie danych docelowej
# Używamy WP-CLI do zrzucenia bazy - bezpieczniejsze niż bezpośrednie operacje mysql
echo "Usuwanie istniejących tabel w bazie danych docelowej..."
"$WP_CLI_BIN" db drop "$WP_CLI_FLAGS" --yes
if [ $? -ne 0 ]; then
    echo "Błąd: Nie udało się usunąć tabel w bazie danych docelowej za pomocą WP-CLI."
    echo "Sprawdź uprawnienia bazy danych dla użytkownika w wp-config.php."
    rm -rf "$FULL_TEMP_DIR"
    exit 1
fi
echo "Istniejące tabele usunięte."

# Import nowej bazy danych
echo "Importowanie bazy danych z backupu: $SQL_FILE"
"$WP_CLI_BIN" db import "$SQL_FILE" "$WP_CLI_FLAGS"
if [ $? -ne 0 ]; then
    echo "Błąd: Nie udało się zaimportować bazy danych z backupu."
    rm -rf "$FULL_TEMP_DIR"
    exit 1
fi
echo "Baza danych zaimportowana."

# Aktualizacja URL-i w bazie danych
echo "Aktualizacja URL-i w bazie danych: zamiana '$SOURCE_DOMAIN' na '$NEW_URL'..."
# WP-CLI search-replace jest inteligentne i domyślnie obsługuje serializowane dane
# Próbujemy zamienić popularne warianty URL starej strony na nowy URL docelowy
"$WP_CLI_BIN" search-replace "http://$SOURCE_DOMAIN" "$NEW_URL" "$WP_CLI_FLAGS" --recurse-objects --skip-columns=guid --precise --all-tables --report-changed-only
"$WP_CLI_BIN" search-replace "https://$SOURCE_DOMAIN" "$NEW_URL" "$WP_CLI_FLAGS" --recurse-objects --skip-columns=guid --precise --all-tables --report-changed-only
"$WP_CLI_BIN" search-replace "http://www.$SOURCE_DOMAIN" "$NEW_URL" "$WP_CLI_FLAGS" --recurse-objects --skip-columns=guid --precise --all-tables --report-changed-only
"$WP_CLI_BIN" search-replace "https://www.$SOURCE_DOMAIN" "$NEW_URL" "$WP_CLI_FLAGS" --recurse-objects --skip-columns=guid --precise --all-tables --report-changed-only

# Opcjonalnie: Zamień tylko siteurl i home, jeśli wiesz, że to wystarczy
# "$WP_CLI_BIN" option update siteurl "$NEW_URL" "$WP_CLI_FLAGS"
# "$WP_CLI_BIN" option update home "$NEW_URL" "$WP_CLI_FLAGS"

echo "Aktualizacja URL-i zakończona."

# --- Migracja plików (TERAZ JESTEŚMY W WP_ROOT_DIR) ---
echo "Rozpoczęcie migracji plików..."

# Zachowaj docelowy wp-config.php
if [ -f "$WP_ROOT_DIR/wp-config.php" ]; then
    echo "Zachowywanie docelowego wp-config.php..."
    cp "$WP_ROOT_DIR/wp-config.php" "$FULL_TEMP_WP_CONFIG_PATH"
    if [ $? -ne 0 ]; then echo "Błąd: Nie udało się zachować docelowego wp-config.php"; rm -rf "$FULL_TEMP_DIR"; exit 1; fi
else
     echo "Błąd: Nie znaleziono docelowego wp-config.php!"
     rm -rf "$FULL_TEMP_DIR"
     exit 1
fi

# Usuń istniejące pliki WordPressa (oprócz katalogu backupów i tymczasowych plików)
echo "Usuwanie istniejących plików WordPressa (z wyjątkiem $BACKUP_DIR_NAME i tymczasowych)..."
# Użyj find i usuń tylko te elementy w WP_ROOT_DIR, które NIE SĄ katalogiem backupów, ani tymczasowym katalogiem, ani tymczasowym wp-config, ani docelowym wp-config
find "$WP_ROOT_DIR" -mindepth 1 -maxdepth 1 \
    -not -name "$(basename "$FULL_TEMP_DIR")" \
    -not -name "$(basename "$FULL_TEMP_WP_CONFIG_PATH")" \
    -not -name "wp-config.php" \
    -not -name "$BACKUP_DIR_NAME" \
    -exec rm -rf {} +
if [ $? -ne 0 ]; then echo "Błąd: Wystąpiły problemy podczas usuwania istniejących plików."; rm -rf "$FULL_TEMP_DIR"; exit 1; fi
echo "Istniejące pliki usunięte."

# Przenieś rozpakowane pliki z backupu (oprócz pliku SQL i wp-config.php z backupu)
echo "Przenoszenie plików z backupu z $FULL_TEMP_DIR/ do $WP_ROOT_DIR/ ..."
# Przenieś wszystkie elementy z katalogu tymczasowego, z wyjątkiem pliku SQL, pliku ZIP i wp-config.php z backupu
find "$FULL_TEMP_DIR" -mindepth 1 -maxdepth 1 \
    -not -name "$(basename "$SQL_FILE")" \
    -not -name "$TEMP_ZIP_FILE" \
    -not -name "wp-config.php" \
    -exec mv {} "$WP_ROOT_DIR/" \;
if [ $? -ne 0 ]; then echo "Błąd: Wystąpiły problemy podczas przenoszenia plików z backupu."; rm -rf "$FULL_TEMP_DIR"; exit 1; fi
echo "Pliki z backupu przeniesione."

# Przywróć docelowy wp-config.php
echo "Przywracanie docelowego wp-config.php..."
if [ -f "$FULL_TEMP_WP_CONFIG_PATH" ]; then
    mv "$FULL_TEMP_WP_CONFIG_PATH" "$WP_ROOT_DIR/wp-config.php"
    if [ $? -ne 0 ]; then echo "Błąd: Nie udało się przywrócić docelowego wp-config.php"; rm -rf "$FULL_TEMP_DIR"; exit 1; fi
    echo "Docelowy wp-config.php przywrócony."
else
     echo "Błąd: Tymczasowy plik wp-config.php nie istnieje! Krytyczny błąd!"
     rm -rf "$FULL_TEMP_DIR"
     exit 1
fi


# --- Ustawienie uprawnień plików (TERAZ JESTEŚMY W WP_ROOT_DIR) ---
# Założenie: Użytkownik webservera to www-data, standardowe uprawnienia 755/644
echo "Ustawianie uprawnień plików (chown www-data:www-data, chmod 755/644) w $WP_ROOT_DIR..."
# Zmień właściciela na użytkownika serwera WWW
chown -R www-data:www-data "$WP_ROOT_DIR"
if [ $? -ne 0 ]; then echo "Ostrzeżenie: Nie udało się zmienić właściciela plików."; fi

# Ustaw uprawnienia dla katalogów (755) i plików (644)
find "$WP_ROOT_DIR" -type d -exec chmod 755 {} +
if [ $? -ne 0 ]; then echo "Ostrzeżenie: Nie udało się ustawić uprawnień dla katalogów."; fi
find "$WP_ROOT_DIR" -type f -exec chmod 644 {} +
if [ $? -ne 0 ]; then echo "Ostrzeżenie: Nie udało się ustawić uprawnień dla plików."; fi

# Ustaw specjalne uprawnienia dla wp-config.php (opcjonalnie, 600 lub 640)
chmod 640 "$WP_ROOT_DIR/wp-config.php" 2>/dev/null # Nie wszystkie serwery tego wymagają, ignoruj błąd jeśli się pojawi
# Upewnij się, że katalog backupów ma odpowiednie uprawnienia (powinien mieć z aktywacji wtyczki, ale na wszelki wypadek)
mkdir -p "$FULL_BACKUP_DIR" # Upewnij się, że katalog backupów istnieje na docelowym serwerze po migracji
chown -R www-data:www-data "$FULL_BACKUP_DIR"
chmod 755 "$FULL_BACKUP_DIR"
# Upewnij się, że katalog uploads ma odpowiednie uprawnienia
mkdir -p "$WP_ROOT_DIR/wp-content/uploads"
chown -R www-data:www-data "$WP_ROOT_DIR/wp-content/uploads"
chmod 755 "$WP_ROOT_DIR/wp-content/uploads"


echo "Uprawnienia plików ustawione."


# --- WP-CLI - kroki po migracji (TERAZ JESTEŚMY W WP_ROOT_DIR) ---
echo "Wykonywanie końcowych operacji WP-CLI..."

# Aktualizacja permanentnych linków/reguł przepisywania
echo "Odświeżanie permanentnych linków..."
"$WP_CLI_BIN" rewrite flush "$WP_CLI_FLAGS" --hard
if [ $? -ne 0 ]; then echo "Ostrzeżenie: Nie udało się odświeżyć permanentnych linków."; fi

# Aktualizacja opcji (np. upewnij się, że wszystko jest OK po search-replace)
"$WP_CLI_BIN" option update siteurl "$NEW_URL" "$WP_CLI_FLAGS" 2>/dev/null # Ustaw URL ponownie na wszelki wypadek
"$WP_CLI_BIN" option update home "$NEW_URL" "$WP_CLI_FLAGS" 2>/dev/null

# Opcjonalnie: Zaktualizuj rdzeń, wtyczki i motywy
echo "Aktualizacja rdzenia, wtyczek i motywów (opcjonalnie)..."
"$WP_CLI_BIN" core update "$WP_CLI_FLAGS"
"$WP_CLI_BIN" plugin update --all "$WP_CLI_FLAGS"
"$WP_CLI_BIN" theme update --all "$WP_CLI_FLAGS"

# Wyczyść cache WP (jeśli istnieje)
echo "Czyszczenie cache WP..."
"$WP_CLI_BIN" cache flush "$WP_CLI_FLAGS" 2>/dev/null # Ignoruj błąd, jeśli cache nie istnieje

echo "Operacje WP-CLI zakończone."


# --- Sprzątanie (TERAZ JESTEŚMY W WP_ROOT_DIR) ---
echo "Sprzątanie plików tymczasowych..."
# Upewnij się, że usuwasz katalog tymczasowy stworzony W WP_ROOT_DIR
rm -rf "$FULL_TEMP_DIR"
echo "Sprzątanie zakończone."

echo ""
echo "---------------------------------------------------"
echo "Migracja zakończona pomyślnie!"
echo "Docelowa strona powinna teraz działać pod adresem: $NEW_URL"
echo "Pamiętaj o ręcznym sprawdzeniu strony po migracji!"
echo "---------------------------------------------------"

exit 0