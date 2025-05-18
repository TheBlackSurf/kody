#!/bin/bash

# deploy.sh - Skrypt do wdrażania aplikacji Django z repozytorium GitHub.
# Użycie: ./deploy.sh <repo_url> <domain> [www_alias_domain]
# Przykład: ./deploy.sh https://github.com/user/myproject.git example.com
# Przykład: ./deploy.sh https://github.com/user/myproject.git example.com www.example.com

set -e
set -o pipefail

# --- Konfiguracja ---
DEPLOY_DIR="/var/www/django"
NGINX_SITES_AVAILABLE_DIR="/etc/nginx/sites-available"
NGINX_SITES_ENABLED_DIR="/etc/nginx/sites-enabled"
NGINX_CONF_FILENAME="django.conf"
NGINX_CONF_FILE_PATH="${NGINX_SITES_AVAILABLE_DIR}/${NGINX_CONF_FILENAME}"

GUNICORN_SERVICE_RUNTIME_DIR_NAME="gunicorn_django"
GUNICORN_SOCKET_PATH="/run/${GUNICORN_SERVICE_RUNTIME_DIR_NAME}/socket"
GUNICORN_SERVICE_FILE="/etc/systemd/system/gunicorn_django.service"
VENV_NAME="venv"
DEPLOY_LOG_FILE="/var/log/django_deploy.log"
SETTINGS_UPDATER_PY_SCRIPT_PATH="/tmp/update_django_settings_$(date +%s).py"

DEPLOY_USER="www-data"
DEPLOY_GROUP="www-data"

# --- Funkcje Pomocnicze ---
C_GREEN='\033[0;32m'
C_YELLOW='\033[1;33m'
C_RED='\033[0;31m'
C_NC='\033[0m' # No Color

log_msg() {
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') - ${C_GREEN}[INFO]${C_NC} $1" | tee -a "$DEPLOY_LOG_FILE"
}
log_warn() {
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') - ${C_YELLOW}[WARN]${C_NC} $1" | tee -a "$DEPLOY_LOG_FILE"
}
log_error() {
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') - ${C_RED}[ERROR]${C_NC} $1" | tee -a "$DEPLOY_LOG_FILE"
}
log_debug() {
    if [ "${DEBUG_MODE:-false}" = true ]; then
        echo -e "$(date '+%Y-%m-%d %H:%M:%S') - [DEBUG] $1" | tee -a "$DEPLOY_LOG_FILE"
    fi
}

DJANGO_PROJECT_NAME=""
PYTHON_VENV_PATH=""
PYTHON_EXEC_PATH=""
PIP_EXEC_PATH=""

cleanup_temp_files() {
    log_debug "Rozpoczynanie czyszczenia plików tymczasowych..."
    rm -f "$SETTINGS_UPDATER_PY_SCRIPT_PATH"
    log_debug "Zakończono czyszczenie plików tymczasowych."
}

trap 'exit_code=$?; log_error "Wystąpił błąd (kod wyjścia: $exit_code) w linii $LINENO skryptu $0."; cleanup_temp_files; exit $exit_code;' ERR
trap 'cleanup_temp_files; log_msg "Skrypt wdrożeniowy zakończył pracę.";' EXIT


# --- Główny Skrypt ---
log_msg "Uruchamianie skryptu wdrożeniowego Django..."
echo "--- Log dla deploy $(date) ---" >> "$DEPLOY_LOG_FILE"

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
    log_error "Nieprawidłowa liczba argumentów."
    log_error "Użycie: $0 <link_repozytorium_github> <główna_domena> [alias_www_domeny (np. www.domena.pl)]"
    exit 1
fi

GITHUB_REPO_URL="$1"
MAIN_DOMAIN="$2"
WWW_ALIAS_DOMAIN="${3:-}"

log_msg "Repozytorium GitHub: $GITHUB_REPO_URL"
log_msg "Główna domena: $MAIN_DOMAIN"
if [ -n "$WWW_ALIAS_DOMAIN" ]; then log_msg "Alias WWW domeny: $WWW_ALIAS_DOMAIN"; fi
if [ "$(id -u)" -ne 0 ]; then log_error "Ten skrypt musi być uruchomiony z uprawnieniami root-a (np. przez sudo)."; exit 1; fi

REQUIRED_TOOLS=("git" "python3" "python3-pip" "python3-venv" "nginx" "curl" "file" "iconv")
for tool in "${REQUIRED_TOOLS[@]}"; do
    if ! command -v "$tool" &> /dev/null; then
        log_warn "Narzędzie '$tool' nie znalezione. Próba instalacji..."
        apt-get update -y >/dev/null 2>&1 || log_warn "Nie udało się zaktualizować listy pakietów. Kontynuuję..."
        apt-get install -y "$tool" || log_error "Nie udało się zainstalować '$tool'. Przerywam."
        log_msg "Zainstalowano '$tool'."
    fi
done

TIMESTAMP=$(date +%Y%m%d%H%M%S)
if [ -f "$NGINX_CONF_FILE_PATH" ]; then log_msg "Tworzenie kopii zapasowej Nginx: ${NGINX_CONF_FILE_PATH}.${TIMESTAMP}.bak"; cp "$NGINX_CONF_FILE_PATH" "${NGINX_CONF_FILE_PATH}.${TIMESTAMP}.bak"; fi
if [ -f "$GUNICORN_SERVICE_FILE" ]; then log_msg "Tworzenie kopii zapasowej Gunicorn: ${GUNICORN_SERVICE_FILE}.${TIMESTAMP}.bak"; cp "$GUNICORN_SERVICE_FILE" "${GUNICORN_SERVICE_FILE}.${TIMESTAMP}.bak"; fi

log_msg "Zatrzymywanie usług Gunicorn i Nginx..."
systemctl stop gunicorn_django.service || log_warn "Usługa Gunicorn nie była uruchomiona lub nie udało się jej zatrzymać."

log_msg "Czyszczenie starego wdrożenia w $DEPLOY_DIR..."
if [ -d "$DEPLOY_DIR" ]; then
    find "$DEPLOY_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} \;
else
    mkdir -p "$DEPLOY_DIR"; log_msg "Utworzono katalog $DEPLOY_DIR.";
fi
chown "${DEPLOY_USER}:${DEPLOY_GROUP}" "$DEPLOY_DIR"; chmod 755 "$DEPLOY_DIR"

log_msg "Klonowanie aplikacji z $GITHUB_REPO_URL..."
TEMP_CLONE_DIR=$(mktemp -d)
if git clone --depth 1 "$GITHUB_REPO_URL" "$TEMP_CLONE_DIR"; then
    rsync -a --delete --exclude='.git/' "$TEMP_CLONE_DIR/" "$DEPLOY_DIR/"
    rm -rf "$TEMP_CLONE_DIR"; log_msg "Pomyślnie sklonowano repozytorium.";
else
    log_error "Nie udało się sklonować repozytorium z $GITHUB_REPO_URL."; rm -rf "$TEMP_CLONE_DIR"; exit 1;
fi
chown -R "${DEPLOY_USER}:${DEPLOY_GROUP}" "${DEPLOY_DIR}"

log_msg "Wykrywanie struktury projektu Django..."
if [ ! -f "$DEPLOY_DIR/manage.py" ]; then log_error "Nie znaleziono pliku manage.py w $DEPLOY_DIR."; exit 1; fi

DJANGO_PROJECT_MODULE_DIR_PATH=$(find "$DEPLOY_DIR" -mindepth 1 -maxdepth 1 -type d -exec test -f "{}/settings.py" \; -print -quit)
if [ -z "$DJANGO_PROJECT_MODULE_DIR_PATH" ]; then
    DJANGO_PROJECT_MODULE_DIR_PATH=$(find "$DEPLOY_DIR" -mindepth 2 -maxdepth 2 -type d -exec test -f "{}/settings.py" \; -print -quit)
fi

if [ -z "$DJANGO_PROJECT_MODULE_DIR_PATH" ] || [ ! -d "$DJANGO_PROJECT_MODULE_DIR_PATH" ]; then log_error "Nie udało się automatycznie określić katalogu projektu Django."; exit 1; fi
DJANGO_PROJECT_NAME=$(basename "$DJANGO_PROJECT_MODULE_DIR_PATH")
DJANGO_SETTINGS_PY_PATH="${DJANGO_PROJECT_MODULE_DIR_PATH}/settings.py"

log_msg "Wykryty katalog projektu Django: $DJANGO_PROJECT_MODULE_DIR_PATH"
log_msg "Wykryta nazwa modułu projektu Django (dla WSGI/ASGI): $DJANGO_PROJECT_NAME"
log_msg "Ścieżka do settings.py: $DJANGO_SETTINGS_PY_PATH"
if [ ! -f "$DJANGO_SETTINGS_PY_PATH" ]; then log_error "Plik settings.py nie istnieje: $DJANGO_SETTINGS_PY_PATH"; exit 1; fi

PYTHON_VENV_PATH="${DEPLOY_DIR}/${VENV_NAME}"
PYTHON_EXEC_PATH="${PYTHON_VENV_PATH}/bin/python"
PIP_EXEC_PATH="${PYTHON_VENV_PATH}/bin/pip"

log_msg "Konfigurowanie środowiska wirtualnego Python w $PYTHON_VENV_PATH..."
if [ -d "$PYTHON_VENV_PATH" ]; then log_warn "Usuwanie istniejącego środowiska: $PYTHON_VENV_PATH"; rm -rf "$PYTHON_VENV_PATH"; fi
python3 -m venv "$PYTHON_VENV_PATH"
log_msg "Środowisko wirtualne utworzone."
"$PIP_EXEC_PATH" install --upgrade pip wheel
log_msg "Zaktualizowano pip i wheel."

REQUIREMENTS_FILE_PATH="${DEPLOY_DIR}/requirements.txt"
if [ ! -f "$REQUIREMENTS_FILE_PATH" ] && [ -f "${DEPLOY_DIR}/req.txt" ]; then
    REQUIREMENTS_FILE_PATH="${DEPLOY_DIR}/req.txt"; log_warn "Używam req.txt jako pliku wymagań.";
fi

if [ -f "$REQUIREMENTS_FILE_PATH" ]; then
    log_msg "Przetwarzanie pliku wymagań: $REQUIREMENTS_FILE_PATH"
    if grep -qE "^psycopg2([^-]|$)" "$REQUIREMENTS_FILE_PATH"; then
        if ! dpkg -s libpq-dev &> /dev/null; then
            log_warn "'psycopg2' znaleziony, a 'libpq-dev' nie jest zainstalowany. Instaluję...";
            apt-get update -y && apt-get install -y libpq-dev || log_error "Nie udało się zainstalować libpq-dev."
        fi
    fi
    ORIG_ENCODING=$(file -b --mime-encoding "$REQUIREMENTS_FILE_PATH")
    log_debug "Wykryte kodowanie dla $REQUIREMENTS_FILE_PATH: $ORIG_ENCODING"
    TEMP_REQ_UTF8=$(mktemp)
    if [[ "$ORIG_ENCODING" == "unknown" ]] || [[ "$ORIG_ENCODING" == "us-ascii" ]] || [[ "$ORIG_ENCODING" == "utf-8" ]]; then
        sed '1s/^\xef\xbb\xbf//' "$REQUIREMENTS_FILE_PATH" | tr -d '\r' > "$TEMP_REQ_UTF8"
    else
        if iconv -f "$ORIG_ENCODING" -t "UTF-8//TRANSLIT" "$REQUIREMENTS_FILE_PATH" | sed '1s/^\xef\xbb\xbf//' | tr -d '\r' > "$TEMP_REQ_UTF8"; then
            log_msg "Konwersja kodowania zakończona."
        else log_warn "Nie udało się przekonwertować kodowania $REQUIREMENTS_FILE_PATH."; cp "$REQUIREMENTS_FILE_PATH" "$TEMP_REQ_UTF8"; fi
    fi
    log_msg "Instalowanie zależności z $TEMP_REQ_UTF8 (zachowując wersje)..."
    if "$PIP_EXEC_PATH" install -r "$TEMP_REQ_UTF8"; then log_msg "Zależności zainstalowane."; else log_error "Błąd instalacji zależności."; exit 1; fi
    rm -f "$TEMP_REQ_UTF8"
else
    log_warn "Brak requirements.txt/req.txt. Instaluję tylko Django i Gunicorn."; "$PIP_EXEC_PATH" install django gunicorn;
fi

if ! "$PIP_EXEC_PATH" show gunicorn &> /dev/null; then log_msg "Instalowanie Gunicorn..."; "$PIP_EXEC_PATH" install gunicorn; fi
log_msg "Gunicorn jest zainstalowany."

cat > "$SETTINGS_UPDATER_PY_SCRIPT_PATH" << 'EOF_PYTHON_SETTINGS_UPDATER'
# Początek settings_updater.py
import sys
import re
import os
from pathlib import Path

def log_py(m):
    print(f"PYTHON_SETTINGS_UPDATER: {m}", file=sys.stderr)

def find_setting_block_indices(lines, key):
    # Pattern for simple assignment or start of a list/tuple
    key_pattern = re.compile(rf"^\s*{re.escape(key)}\s*=\s*(\[|\(|\{{|True|False|None|['\"0-9])")
    start_index, end_index = -1, -1
    open_brackets = 0
    open_parentheses = 0
    open_braces = 0 # For dicts, though less common for these settings
    in_block_for_key = False

    for i, line in enumerate(lines):
        stripped_line = line.strip()
        
        if not in_block_for_key:
            if key_pattern.match(stripped_line):
                start_index = i
                in_block_for_key = True
                
                # Count brackets/parentheses on the starting line
                open_brackets += line.count('[') - line.count(']')
                open_parentheses += line.count('(') - line.count(')')
                open_braces += line.count('{') - line.count('}')

                # If it's a single-line assignment (simple value or fully contained list/tuple/dict)
                if open_brackets == 0 and open_parentheses == 0 and open_braces == 0:
                    end_index = i
                    break 
        elif in_block_for_key:
            open_brackets += line.count('[') - line.count(']')
            open_parentheses += line.count('(') - line.count(')')
            open_braces += line.count('{') - line.count('}')
            
            if open_brackets == 0 and open_parentheses == 0 and open_braces == 0:
                end_index = i
                break
            elif i == len(lines) - 1: # Reached end of file while block is still open
                log_py(f"OSTRZEŻENIE: Blok dla '{key}' wydaje się być niekompletny na końcu pliku.")
                end_index = i # Treat as end of block anyway
                break
                
    return start_index, end_index

def update_setting_smart(lines, key, value_repr, comment=""):
    start_idx, end_idx = find_setting_block_indices(lines, key)
    
    setting_line = f"{key} = {value_repr}  {comment}\n"

    if start_idx != -1 and end_idx != -1: # Setting found, replace its block
        log_py(f"Ustawienie '{key}' znalezione między liniami {start_idx+1}-{end_idx+1}. Zastępowanie.")
        # Ensure consistent newlines by splitting the new setting line if it's multiline
        new_setting_lines = [l + '\n' for l in setting_line.strip().split('\n')]
        lines = lines[:start_idx] + new_setting_lines + lines[end_idx+1:]
    else: # Setting not found, add it
        log_py(f"Ustawienie '{key}' nie znalezione. Dodawanie nowego.")
        insertion_point = 0
        base_dir_idx = -1
        last_import_idx = -1
        # Try to find BASE_DIR more reliably
        for i, line in enumerate(lines):
            s_line = line.strip()
            if re.match(r"^\s*BASE_DIR\s*=\s*(Path\(|os\.path\.dirname\()", s_line):
                base_dir_idx = i
            if s_line.startswith("import ") or s_line.startswith("from "):
                last_import_idx = i
        
        if base_dir_idx != -1:
            insertion_point = base_dir_idx + 1
            for i in range(base_dir_idx + 1, len(lines)):
                if lines[i].strip() == "" or lines[i].strip().startswith("#") or \
                   lines[i].strip().startswith("import ") or lines[i].strip().startswith("from ") or \
                   re.match(r"^[A-Z_0-9]+\s*=", lines[i].strip()):
                    insertion_point = i 
                    break
                insertion_point = i + 1 
        elif last_import_idx != -1:
            insertion_point = last_import_idx + 1
            while insertion_point < len(lines) and (lines[insertion_point].strip() == "" or lines[insertion_point].strip().startswith("#")):
                insertion_point += 1
        else: 
            insertion_point = 0
            while insertion_point < len(lines) and (lines[insertion_point].strip() == "" or lines[insertion_point].strip().startswith("#")):
                insertion_point +=1
                
        lines.insert(insertion_point, setting_line)
    return lines

def main():
    if len(sys.argv) != 7:
        log_py(f"Błąd: Nieprawidłowa liczba argumentów. Oczekiwano 6, otrzymano {len(sys.argv)-1}")
        sys.exit(1)

    settings_file_path, new_allowed_hosts_csv, fixed_csrf_origins_csv, django_deploy_dir, project_module_name, is_debug_str = sys.argv[1:7]
    is_debug = is_debug_str.lower() == 'true'

    log_py(f"Aktualizacja: {settings_file_path}")
    log_py(f"DEBUG -> {is_debug}")
    log_py(f"ALLOWED_HOSTS (skrypt) -> '{new_allowed_hosts_csv}'")
    log_py(f"CSRF_TRUSTED_ORIGINS (stałe ze skryptu) -> '{fixed_csrf_origins_csv}'")
    log_py(f"Katalog wdrożenia (dla STATIC/MEDIA): '{django_deploy_dir}'")

    try:
        with open(settings_file_path, 'r', encoding='utf-8') as f: lines = f.readlines()
    except Exception as e: log_py(f"BŁĄD KRYTYCZNY: Czytanie {settings_file_path}: {e}"); sys.exit(1)

    lines = update_setting_smart(lines, "DEBUG", "True" if is_debug else "False", "# Zmienione przez skrypt")

    # ALLOWED_HOSTS: Merge existing with new from script
    final_allowed_hosts = set(['127.0.0.1', 'localhost'])
    start_idx_ah, end_idx_ah = find_setting_block_indices(lines, "ALLOWED_HOSTS")
    if start_idx_ah != -1:
        block_str_ah = "".join(lines[start_idx_ah : end_idx_ah+1])
        match_ah = re.search(r'\[(.*?)\]', block_str_ah, re.DOTALL)
        if match_ah: final_allowed_hosts.update([h.strip().strip("'\"") for h in match_ah.group(1).split(',') if h.strip()])
    if new_allowed_hosts_csv: final_allowed_hosts.update([h.strip() for h in new_allowed_hosts_csv.split(',') if h.strip()])
    lines = update_setting_smart(lines, "ALLOWED_HOSTS", f"[{', '.join(sorted([repr(h) for h in final_allowed_hosts]))}]")
    
    # CSRF_TRUSTED_ORIGINS: Merge existing with FIXED new from script
    final_csrf_origins = set()
    start_idx_csrf, end_idx_csrf = find_setting_block_indices(lines, "CSRF_TRUSTED_ORIGINS")
    if start_idx_csrf != -1: # Parse existing if any
        block_str_csrf = "".join(lines[start_idx_csrf : end_idx_csrf+1])
        match_csrf = re.search(r'\[(.*?)\]', block_str_csrf, re.DOTALL)
        if match_csrf: final_csrf_origins.update([o.strip().strip("'\"") for o in match_csrf.group(1).split(',') if o.strip()])
    # Add the fixed origins passed from the bash script
    if fixed_csrf_origins_csv:
        final_csrf_origins.update([o.strip() for o in fixed_csrf_origins_csv.split(',') if o.strip()])
    
    lines = update_setting_smart(lines, "CSRF_TRUSTED_ORIGINS", f"[{', '.join(sorted([repr(o) for o in final_csrf_origins]))}]")

    base_dir_defined_pathlib = any("BASE_DIR = Path(__file__)" in line for line in lines)
    base_dir_defined_ospath = any(re.search(r"BASE_DIR\s*=\s*os\.path\.dirname", line) for line in lines)

    static_root_val = repr(os.path.join(django_deploy_dir, "staticfiles_collected"))
    media_root_val = repr(os.path.join(django_deploy_dir, "mediafiles"))
    
    if base_dir_defined_pathlib:
        static_root_val = "BASE_DIR / 'staticfiles_collected'"
        media_root_val = "BASE_DIR / 'mediafiles'"
    elif base_dir_defined_ospath:
        static_root_val = "os.path.join(BASE_DIR, 'staticfiles_collected')"
        media_root_val = "os.path.join(BASE_DIR, 'mediafiles')"
    
    lines = update_setting_smart(lines, "STATIC_ROOT", static_root_val)
    lines = update_setting_smart(lines, "MEDIA_ROOT", media_root_val)
    lines = update_setting_smart(lines, "STATIC_URL", "'/static/'")
    lines = update_setting_smart(lines, "MEDIA_URL", "'/media/'")
    lines = update_setting_smart(lines, "STATICFILES_DIRS", "[]", "# Wyczyczone/ustawione przez skrypt deploy.sh")

    needs_os = ("os.path.join(" in static_root_val or "os.path.join(" in media_root_val) and not any(re.match(r"^\s*import\s+os", line) for line in lines)
    needs_pathlib = ("BASE_DIR / " in static_root_val or "BASE_DIR / " in media_root_val) and not any(re.match(r"^\s*from\s+pathlib\s+import\s+Path", line) for line in lines)

    if needs_os or needs_pathlib:
        import_insertion_point = 0
        for i, line_content in enumerate(lines):
            if not line_content.strip().startswith('#') and line_content.strip() != "": import_insertion_point = i; break
        if needs_os and not has_os: lines.insert(import_insertion_point, "import os\n"); log_py("Dodano 'import os'"); import_insertion_point +=1
        if needs_pathlib and not has_pathlib: lines.insert(import_insertion_point, "from pathlib import Path\n"); log_py("Dodano 'from pathlib import Path'")

    try:
        with open(settings_file_path, 'w', encoding='utf-8') as f: f.writelines(lines)
        log_py(f"Pomyślnie zaktualizowano plik: {settings_file_path}")
    except Exception as e: log_py(f"BŁĄD KRYTYCZNY: Zapis {settings_file_path}: {e}"); sys.exit(1)

if __name__ == "__main__":
    main()
# Koniec settings_updater.py
EOF_PYTHON_SETTINGS_UPDATER
chmod +x "$SETTINGS_UPDATER_PY_SCRIPT_PATH"

# Przygotowanie list domen dla ALLOWED_HOSTS (dynamicznie)
DOMAINS_FOR_PY_ALLOWED_HOSTS="$MAIN_DOMAIN"
AUTO_WWW_DOMAIN="" # Zmienna do przechowania automatycznie wygenerowanej domeny www
if [ -n "$WWW_ALIAS_DOMAIN" ]; then
    DOMAINS_FOR_PY_ALLOWED_HOSTS="${DOMAINS_FOR_PY_ALLOWED_HOSTS},${WWW_ALIAS_DOMAIN}"
elif [[ "$MAIN_DOMAIN" != www.* ]]; then
    AUTO_WWW_DOMAIN="www.${MAIN_DOMAIN}"
    DOMAINS_FOR_PY_ALLOWED_HOSTS="${DOMAINS_FOR_PY_ALLOWED_HOSTS},${AUTO_WWW_DOMAIN}"
fi

# STAŁA lista dla CSRF_TRUSTED_ORIGINS, używając głównej domeny
FIXED_CSRF_ORIGINS_FOR_PY="https://${MAIN_DOMAIN}},http://${MAIN_DOMAIN}}"
if [[ "$MAIN_DOMAIN" != www.* ]]; then # Jeśli domena główna nie jest www, dodaj www
    FIXED_CSRF_ORIGINS_FOR_PY="${FIXED_CSRF_ORIGINS_FOR_PY},https://www.${MAIN_DOMAIN}},http://www.${MAIN_DOMAIN}}"
elif [ -n "$WWW_ALIAS_DOMAIN" ] && [[ "$WWW_ALIAS_DOMAIN" == www.* ]]; then # Jeśli podano alias www, dodaj go
    FIXED_CSRF_ORIGINS_FOR_PY="${FIXED_CSRF_ORIGINS_FOR_PY},https://${WWW_ALIAS_DOMAIN}},http://${WWW_ALIAS_DOMAIN}}"
fi

log_msg "Konfigurowanie pliku settings.py ($DJANGO_SETTINGS_PY_PATH)..."
if ! "$PYTHON_EXEC_PATH" "$SETTINGS_UPDATER_PY_SCRIPT_PATH" \
    "$DJANGO_SETTINGS_PY_PATH" \
    "$DOMAINS_FOR_PY_ALLOWED_HOSTS" \
    "$FIXED_CSRF_ORIGINS_FOR_PY" \
    "$DEPLOY_DIR" \
    "$DJANGO_PROJECT_NAME" \
    "false"; then # DEBUG=false
    log_error "Skrypt Pythona do aktualizacji settings.py ($SETTINGS_UPDATER_PY_SCRIPT_PATH) zakończył się błędem."
    exit 1
fi
log_msg "Plik settings.py skonfigurowany."
rm -f "$SETTINGS_UPDATER_PY_SCRIPT_PATH"

log_msg "Uruchamianie poleceń zarządzania Django..."
mkdir -p "${DEPLOY_DIR}/staticfiles_collected"
mkdir -p "${DEPLOY_DIR}/mediafiles"
chown -R "${DEPLOY_USER}:${DEPLOY_GROUP}" "${DEPLOY_DIR}/staticfiles_collected" "${DEPLOY_DIR}/mediafiles"

cd "$DEPLOY_DIR"

log_msg "Uruchamianie collectstatic..."
if "$PYTHON_EXEC_PATH" manage.py collectstatic --noinput --clear; then
    log_msg "Polecenie collectstatic zakończone pomyślnie."
else
    log_error "Polecenie collectstatic nie powiodło się. Sprawdź logi powyżej oraz $DEPLOY_LOG_FILE."
    # Dodatkowe logowanie błędu collectstatic
    "$PYTHON_EXEC_PATH" manage.py collectstatic --noinput --clear >> "$DEPLOY_LOG_FILE" 2>&1 || true 
    exit 1
fi

log_msg "Uruchamianie migracji bazy danych..."
if "$PYTHON_EXEC_PATH" manage.py migrate --noinput; then
    log_msg "Migracje bazy danych zakończone pomyślnie."
else
    log_error "Migracje Django nie powiodły się. Sprawdź logi powyżej oraz $DEPLOY_LOG_FILE."
    exit 1
fi

log_msg "Konfigurowanie usługi Gunicorn..."
cat > "$GUNICORN_SERVICE_FILE" << EOF
[Unit]
Description=Gunicorn daemon for Django project at $DEPLOY_DIR
Requires=network.target gunicorn_${GUNICORN_SERVICE_RUNTIME_DIR_NAME}.socket
After=network.target gunicorn_${GUNICORN_SERVICE_RUNTIME_DIR_NAME}.socket

[Service]
User=$DEPLOY_USER
Group=$DEPLOY_GROUP
WorkingDirectory=$DEPLOY_DIR
ExecStart=${PYTHON_VENV_PATH}/bin/gunicorn --access-logfile - --error-logfile - --workers 3 --bind unix:${GUNICORN_SOCKET_PATH} ${DJANGO_PROJECT_NAME}.wsgi:application
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# Oddzielny plik socket dla Gunicorn, zarządzany przez systemd
if [ ! -f "/etc/systemd/system/gunicorn_${GUNICORN_SERVICE_RUNTIME_DIR_NAME}.socket" ]; then
log_msg "Tworzenie pliku gunicorn_${GUNICORN_SERVICE_RUNTIME_DIR_NAME}.socket..."
cat > "/etc/systemd/system/gunicorn_${GUNICORN_SERVICE_RUNTIME_DIR_NAME}.socket" <<EOF_GUNICORN_SOCKET
[Unit]
Description=gunicorn socket for ${DJANGO_PROJECT_NAME}

[Socket]
ListenStream=${GUNICORN_SOCKET_PATH}
SocketUser=$DEPLOY_USER
SocketGroup=$DEPLOY_GROUP
SocketMode=0660 # Umożliwia Nginx (zwykle w grupie www-data) odczyt/zapis

[Install]
WantedBy=sockets.target
EOF_GUNICORN_SOCKET
systemctl enable "gunicorn_${GUNICORN_SERVICE_RUNTIME_DIR_NAME}.socket"
systemctl start "gunicorn_${GUNICORN_SERVICE_RUNTIME_DIR_NAME}.socket"
fi

log_msg "Plik usługi Gunicorn ($GUNICORN_SERVICE_FILE) utworzony/zaktualizowany."

log_msg "Konfigurowanie Nginx..."
NGINX_SERVER_NAMES_LINE_CONTENT="$MAIN_DOMAIN"
if [ -n "$WWW_ALIAS_DOMAIN" ]; then NGINX_SERVER_NAMES_LINE_CONTENT="$NGINX_SERVER_NAMES_LINE_CONTENT $WWW_ALIAS_DOMAIN";
elif [ -n "$AUTO_WWW_DOMAIN" ]; then NGINX_SERVER_NAMES_LINE_CONTENT="$NGINX_SERVER_NAMES_LINE_CONTENT $AUTO_WWW_DOMAIN"; fi

LOG_FILE_PREFIX=$(echo "$MAIN_DOMAIN" | tr '.' '_')
mkdir -p /var/log/nginx

cat > "$NGINX_CONF_FILE_PATH" << EOF_NGINX
server {
    listen 80;
    server_name $NGINX_SERVER_NAMES_LINE_CONTENT;

    access_log /var/log/nginx/${LOG_FILE_PREFIX}.access.log;
    error_log /var/log/nginx/${LOG_FILE_PREFIX}.error.log;

    server_tokens off;
    add_header X-Content-Type-Options nosniff;
    add_header X-XSS-Protection "1; mode=block";

    location = /favicon.ico { access_log off; log_not_found off; }
    location = /robots.txt { access_log off; log_not_found off; }

    location /static/ {
        alias ${DEPLOY_DIR}/staticfiles_collected/;
        expires 30d; access_log off;
    }
    location /media/ {
        alias ${DEPLOY_DIR}/mediafiles/;
        expires 30d; access_log off;
    }
    location / {
        include proxy_params;
        proxy_pass http://unix:${GUNICORN_SOCKET_PATH};
    }
}
EOF_NGINX

if [ ! -f "/etc/nginx/proxy_params" ]; then
    log_warn "Plik /etc/nginx/proxy_params nie istnieje. Tworzenie domyślnego."
    cat > "/etc/nginx/proxy_params" <<EOF_PROXY_PARAMS
proxy_set_header Host \$http_host;
proxy_set_header X-Real-IP \$remote_addr;
proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto \$scheme;
proxy_set_header X-Forwarded-Host \$server_name;
EOF_PROXY_PARAMS
fi

log_msg "Plik konfiguracyjny Nginx ($NGINX_CONF_FILE_PATH) utworzony/zaktualizowany."
if [ -L "$NGINX_SITES_ENABLED_DIR/$NGINX_CONF_FILENAME" ] && [ "$(readlink -f "$NGINX_SITES_ENABLED_DIR/$NGINX_CONF_FILENAME")" != "$NGINX_CONF_FILE_PATH" ]; then
    log_warn "Usuwanie starego dowiązania Nginx: $NGINX_SITES_ENABLED_DIR/$NGINX_CONF_FILENAME"; rm -f "$NGINX_SITES_ENABLED_DIR/$NGINX_CONF_FILENAME"; fi
if [ ! -L "$NGINX_SITES_ENABLED_DIR/$NGINX_CONF_FILENAME" ]; then
    ln -s "$NGINX_CONF_FILE_PATH" "$NGINX_SITES_ENABLED_DIR/$NGINX_CONF_FILENAME"; log_msg "Utworzono dowiązanie dla Nginx."; fi

log_msg "Testowanie konfiguracji Nginx..."
if nginx -t; then log_msg "Konfiguracja Nginx jest poprawna."; else log_error "Błąd w konfiguracji Nginx."; exit 1; fi

log_msg "Przeładowywanie demona systemd..."
systemctl daemon-reload

log_msg "Włączanie i restartowanie usług Gunicorn..."
systemctl enable "gunicorn_${GUNICORN_SERVICE_RUNTIME_DIR_NAME}.socket"
systemctl start "gunicorn_${GUNICORN_SERVICE_RUNTIME_DIR_NAME}.socket"
systemctl enable gunicorn_django.service
systemctl restart gunicorn_django.service
log_msg "Czekam 5 sekund na Gunicorn..."
sleep 5 
if ! systemctl is-active --quiet gunicorn_django.service; then
    log_error "Usługa Gunicorn nie uruchomiła się. Sprawdź:";
    log_error "  sudo systemctl status gunicorn_django.service"
    log_error "  sudo journalctl -u gunicorn_django.service -n 50 --no-pager"
    exit 1
fi
log_msg "Usługa Gunicorn pomyślnie (re)startowana."

log_msg "Restartowanie usługi Nginx..."
systemctl restart nginx.service
if ! systemctl is-active --quiet nginx.service; then
    log_error "Usługa Nginx nie uruchomiła się. Sprawdź:";
    log_error "  sudo systemctl status nginx.service"
    log_error "  sudo journalctl -u nginx.service -n 50 --no-pager"
    exit 1
fi
log_msg "Usługa Nginx pomyślnie zrestartowana."

chown -R "${DEPLOY_USER}:${DEPLOY_GROUP}" "${DEPLOY_DIR}"
log_msg "Wdrożenie zakończone pomyślnie!"
log_msg "Aplikacja powinna być dostępna pod adresem: http://$MAIN_DOMAIN"
if [ -n "$AUTO_WWW_DOMAIN" ]; then log_msg "oraz http://$AUTO_WWW_DOMAIN"; fi
if [ -n "$WWW_ALIAS_DOMAIN" ]; then log_msg "oraz http://$WWW_ALIAS_DOMAIN"; fi

exit 0