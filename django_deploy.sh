#!/bin/bash

# deploy.sh - Skrypt do wdrażania aplikacji Django z repozytorium GitHub.
# Użycie: ./deploy.sh <repo_url> <domain> [www_alias_domain]
#   <repo_url>: Adres URL repozytorium Git. Dla repozytoriów prywatnych użyj formatu SSH (np. git@github.com:user/repo.git).
#               Upewnij się, że klucz SSH serwera jest dodany do konta GitHub i ma odpowiednie uprawnienia.
# Przykład (publiczne HTTPS): ./deploy.sh https://github.com/user/myproject.git example.com
# Przykład (prywatne SSH):   ./deploy.sh git@github.com:user/myproject.git example.com
# Przykład (prywatne SSH z aliasem www): ./deploy.sh git@github.com:user/myproject.git example.com www.example.com

set -e
set -o pipefail

# --- Konfiguracja ---
DEPLOY_DIR="/var/www/django"
NGINX_SITES_AVAILABLE_DIR="/etc/nginx/sites-available"
NGINX_SITES_ENABLED_DIR="/etc/nginx/sites-enabled"
NGINX_CONF_FILENAME="django.conf"
NGINX_CONF_FILE_PATH="${NGINX_SITES_AVAILABLE_DIR}/${NGINX_CONF_FILENAME}"

GUNICORN_SERVICE_RUNTIME_DIR_NAME="gunicorn_django" # Nazwa katalogu w /run
GUNICORN_SOCKET_PATH="/run/${GUNICORN_SERVICE_RUNTIME_DIR_NAME}/socket" # Pełna ścieżka do socketu
GUNICORN_SERVICE_FILE="/etc/systemd/system/gunicorn_django.service"
GUNICORN_SOCKET_SYSTEMD_FILE="/etc/systemd/system/${GUNICORN_SERVICE_RUNTIME_DIR_NAME}.socket"

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
DJANGO_PROJECT_MODULE_DIR_PATH="" # Zdefiniuj globalnie, aby było dostępne

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
    log_error "Użycie: $0 <repo_url> <główna_domena> [alias_www_domeny]"
    log_error "   <repo_url>: Dla repozytoriów prywatnych użyj formatu SSH (np. git@github.com:user/repo.git)."
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
        apt-get install -y "$tool" || { log_error "Nie udało się zainstalować '$tool'. Przerywam."; exit 1; }
        log_msg "Zainstalowano '$tool'."
    fi
done

TIMESTAMP=$(date +%Y%m%d%H%M%S)
if [ -f "$NGINX_CONF_FILE_PATH" ]; then log_msg "Tworzenie kopii zapasowej Nginx: ${NGINX_CONF_FILE_PATH}.${TIMESTAMP}.bak"; cp "$NGINX_CONF_FILE_PATH" "${NGINX_CONF_FILE_PATH}.${TIMESTAMP}.bak"; fi
if [ -f "$GUNICORN_SERVICE_FILE" ]; then log_msg "Tworzenie kopii zapasowej Gunicorn: ${GUNICORN_SERVICE_FILE}.${TIMESTAMP}.bak"; cp "$GUNICORN_SERVICE_FILE" "${GUNICORN_SERVICE_FILE}.${TIMESTAMP}.bak"; fi
if [ -f "$GUNICORN_SOCKET_SYSTEMD_FILE" ]; then log_msg "Tworzenie kopii zapasowej Gunicorn socket: ${GUNICORN_SOCKET_SYSTEMD_FILE}.${TIMESTAMP}.bak"; cp "$GUNICORN_SOCKET_SYSTEMD_FILE" "${GUNICORN_SOCKET_SYSTEMD_FILE}.${TIMESTAMP}.bak"; fi


log_msg "Zatrzymywanie usług Gunicorn i Nginx..."
systemctl stop gunicorn_django.service || log_warn "Usługa Gunicorn (service) nie była uruchomiona lub nie udało się jej zatrzymać."
systemctl stop "${GUNICORN_SERVICE_RUNTIME_DIR_NAME}.socket" || log_warn "Usługa Gunicorn (socket) nie była uruchomiona lub nie udało się jej zatrzymać."


log_msg "Czyszczenie starego wdrożenia w $DEPLOY_DIR..."
if [ -d "$DEPLOY_DIR" ]; then
    find "$DEPLOY_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} \;
else
    mkdir -p "$DEPLOY_DIR"; log_msg "Utworzono katalog $DEPLOY_DIR.";
fi
chown "${DEPLOY_USER}:${DEPLOY_GROUP}" "$DEPLOY_DIR"; chmod 755 "$DEPLOY_DIR"

log_msg "Klonowanie aplikacji z $GITHUB_REPO_URL..."
TEMP_CLONE_DIR=$(mktemp -d)
# Użycie GIT_SSH_COMMAND do automatycznego akceptowania nowego klucza hosta GitHub.
if GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null" git clone --depth 1 "$GITHUB_REPO_URL" "$TEMP_CLONE_DIR"; then
    rsync -a --delete --exclude='.git/' "$TEMP_CLONE_DIR/" "$DEPLOY_DIR/"
    rm -rf "$TEMP_CLONE_DIR"; log_msg "Pomyślnie sklonowano repozytorium.";
else
    log_error "Nie udało się sklonować repozytorium z $GITHUB_REPO_URL.";
    log_error "Upewnij się, że URL jest poprawny i że serwer ma dostęp do repozytorium (dla prywatnych repozytoriów sprawdź klucze SSH i ich konfigurację w GitHub).";
    log_error "Sprawdź również, czy użytkownik, jako który uruchamiany jest skrypt (np. root), ma poprawnie skonfigurowany dostęp SSH do GitHub.";
    rm -rf "$TEMP_CLONE_DIR"; exit 1;
fi
chown -R "${DEPLOY_USER}:${DEPLOY_GROUP}" "${DEPLOY_DIR}"

log_msg "Wykrywanie struktury projektu Django..."
if [ ! -f "$DEPLOY_DIR/manage.py" ]; then log_error "Nie znaleziono pliku manage.py w $DEPLOY_DIR."; exit 1; fi

# Przypisanie do globalnie zadeklarowanej zmiennej
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
    if grep -qE "^psycopg2([^-=[:space:]]|$)" "$REQUIREMENTS_FILE_PATH"; then 
        if ! dpkg -s libpq-dev &> /dev/null; then
            log_warn "'psycopg2' znaleziony w requirements.txt, a 'libpq-dev' nie jest zainstalowany. Instaluję libpq-dev..."
            apt-get update -y && apt-get install -y libpq-dev || { log_error "Nie udało się zainstalować libpq-dev."; exit 1; }
        else
            log_debug "Pakiet libpq-dev jest już zainstalowany."
        fi
    fi

    ORIG_ENCODING=$(file -b --mime-encoding "$REQUIREMENTS_FILE_PATH")
    log_debug "Wykryte kodowanie dla $REQUIREMENTS_FILE_PATH: $ORIG_ENCODING"
    
    TEMP_REQ_UTF8=$(mktemp)
    if [[ "$ORIG_ENCODING" == "unknown" ]] || [[ "$ORIG_ENCODING" == "us-ascii" ]] || [[ "$ORIG_ENCODING" == "utf-8" ]]; then
        log_debug "Kodowanie to ASCII/UTF-8 lub nieznane, zakładam kompatybilność lub brak potrzeby konwersji poza BOM/CR."
        sed '1s/^\xef\xbb\xbf//' "$REQUIREMENTS_FILE_PATH" | tr -d '\r' > "$TEMP_REQ_UTF8"
    else
        log_msg "Konwertowanie $REQUIREMENTS_FILE_PATH z $ORIG_ENCODING do UTF-8..."
        if iconv -f "$ORIG_ENCODING" -t "UTF-8//TRANSLIT" "$REQUIREMENTS_FILE_PATH" | sed '1s/^\xef\xbb\xbf//' | tr -d '\r' > "$TEMP_REQ_UTF8"; then
            log_msg "Konwersja kodowania zakończona pomyślnie."
        else
            log_warn "Nie udało się przekonwertować kodowania pliku $REQUIREMENTS_FILE_PATH. Używam oryginalnego pliku."
            cp "$REQUIREMENTS_FILE_PATH" "$TEMP_REQ_UTF8" 
        fi
    fi

    log_msg "Instalowanie zależności z $TEMP_REQ_UTF8 (zachowując wersje)..."
    if "$PIP_EXEC_PATH" install -r "$TEMP_REQ_UTF8"; then
        log_msg "Zależności z pliku wymagań zainstalowane."
    else
        log_error "Błąd podczas instalacji zależności z $REQUIREMENTS_FILE_PATH. Sprawdź logi pip powyżej oraz czy wszystkie pakiety są dostępne w PyPI (i czy ich wersje są poprawne)."
        exit 1
    fi
    rm -f "$TEMP_REQ_UTF8"
else
    log_warn "Brak requirements.txt/req.txt. Instaluję tylko Django i Gunicorn."
    "$PIP_EXEC_PATH" install django gunicorn
fi

if ! "$PIP_EXEC_PATH" show gunicorn &> /dev/null; then
    log_msg "Instalowanie Gunicorn (nie było w requirements.txt lub poprzednia instalacja nie powiodła się)..."
    "$PIP_EXEC_PATH" install gunicorn
fi
log_msg "Gunicorn jest zainstalowany w środowisku wirtualnym."

cat > "$SETTINGS_UPDATER_PY_SCRIPT_PATH" << 'EOF_PYTHON_SETTINGS_UPDATER'
# Początek settings_updater.py
import sys
import re
import os
from pathlib import Path

def log_py(m):
    print(f"PYTHON_SETTINGS_UPDATER: {m}", file=sys.stderr)

def find_setting_block_indices(lines, key):
    key_pattern = re.compile(rf"^\s*{re.escape(key)}\s*=\s*(\[|\(|\{{|True|False|None|['\"0-9])")
    start_index, end_index = -1, -1
    open_brackets = 0 
    open_parentheses = 0
    open_braces = 0 
    in_block_for_key = False
    is_multiline_string = False
    string_delimiter = None

    for i, line in enumerate(lines):
        stripped_line = line.strip()
        
        if not in_block_for_key:
            if key_pattern.match(stripped_line):
                start_index = i
                in_block_for_key = True
                
                # Check for multiline strings
                if "'''" in line or '"""' in line:
                    delimiter_match = re.search(r"(''')|(\"\"\")", line)
                    if delimiter_match:
                        string_delimiter = delimiter_match.group(0)
                        if line.count(string_delimiter) % 2 == 1: # Starts a multiline string
                            is_multiline_string = True
                
                open_brackets += line.count('[') - line.count(']')
                open_parentheses += line.count('(') - line.count(')')
                open_braces += line.count('{') - line.count('}')

                if not is_multiline_string and open_brackets == 0 and open_parentheses == 0 and open_braces == 0:
                    end_index = i
                    break 
        elif in_block_for_key:
            if is_multiline_string:
                if string_delimiter in line:
                    is_multiline_string = False # End of multiline string
            
            open_brackets += line.count('[') - line.count(']')
            open_parentheses += line.count('(') - line.count(')')
            open_braces += line.count('{') - line.count('}')
            
            if not is_multiline_string and open_brackets <= 0 and open_parentheses <= 0 and open_braces <=0 :
                if line.rstrip().endswith(',') and (open_brackets < 0 or open_parentheses < 0 or open_braces < 0) :
                     pass 
                else:
                    end_index = i
                    break
            elif i == len(lines) - 1: 
                log_py(f"OSTRZEŻENIE: Blok dla '{key}' wydaje się być niekompletny na końcu pliku.")
                end_index = i 
                break
                
    return start_index, end_index

def update_setting_smart(lines, key, value_repr, comment="", add_if_not_found=True):
    start_idx, end_idx = find_setting_block_indices(lines, key)
    
    setting_line_content = f"{key} = {value_repr}  {comment}"
    if '\n' in value_repr.strip(): 
        setting_lines_to_insert = [setting_line_content + '\n'] 
    else:
        setting_lines_to_insert = [setting_line_content.rstrip() + '\n']

    if start_idx != -1 and end_idx != -1:
        log_py(f"Ustawienie '{key}' znalezione między liniami {start_idx+1}-{end_idx+1}. Zastępowanie.")
        leading_whitespace = re.match(r"(\s*)", lines[start_idx]).group(1)
        current_lines_to_insert = []
        for line_to_insert in setting_lines_to_insert:
            if line_to_insert.strip() == "": 
                current_lines_to_insert.append(line_to_insert)
            else:
                current_lines_to_insert.append(leading_whitespace + line_to_insert.lstrip())
        setting_lines_to_insert = current_lines_to_insert
        lines = lines[:start_idx] + setting_lines_to_insert + lines[end_idx+1:]
    elif add_if_not_found:
        log_py(f"Ustawienie '{key}' nie znalezione. Dodawanie nowego.")
        insertion_point = 0; base_dir_idx = -1; last_import_idx = -1
        for i, line in enumerate(lines):
            s_line = line.strip()
            if re.match(r"^\s*BASE_DIR\s*=\s*(Path\(|os\.path\.dirname\()", s_line): base_dir_idx = i
            if s_line.startswith("import ") or s_line.startswith("from "): last_import_idx = i
        
        if base_dir_idx != -1: 
            insertion_point = base_dir_idx + 1
            while insertion_point < len(lines) and (lines[insertion_point].strip() == "" or lines[insertion_point].strip().startswith("#")):
                insertion_point += 1
        elif last_import_idx != -1: 
            insertion_point = last_import_idx + 1
            while insertion_point < len(lines) and (lines[insertion_point].strip() == "" or lines[insertion_point].strip().startswith("#")):
                insertion_point += 1
        else: 
            while insertion_point < len(lines) and (lines[insertion_point].strip() == "" or lines[insertion_point].strip().startswith("#")):
                insertion_point +=1
        
        if insertion_point > 0 and lines[insertion_point-1].strip() != "":
            lines.insert(insertion_point, "\n")
            insertion_point += 1
        
        for line_to_insert_idx, line_to_insert in enumerate(setting_lines_to_insert):
             lines.insert(insertion_point + line_to_insert_idx, line_to_insert)

        if insertion_point + len(setting_lines_to_insert) < len(lines) and \
           lines[insertion_point + len(setting_lines_to_insert)].strip() != "" and \
           not (value_repr.strip().startswith("[") and value_repr.strip().endswith("]")) and \
           not (value_repr.strip().startswith("(") and value_repr.strip().endswith(")")):
            lines.insert(insertion_point + len(setting_lines_to_insert), "\n")
    else:
        log_py(f"Ustawienie '{key}' nie znalezione. Nie będzie dodawane (add_if_not_found=False).")
    return lines

def main():
    if len(sys.argv) != 7: log_py(f"Błąd: Nieprawidłowa liczba argumentów. Oczekiwano 6, otrzymano {len(sys.argv)-1}"); sys.exit(1)
    settings_file_path, new_allowed_hosts_csv, fixed_csrf_origins_csv, django_deploy_dir, project_module_name, is_debug_str = sys.argv[1:7]
    is_debug = is_debug_str.lower() == 'true'
    log_py(f"Aktualizacja: {settings_file_path}; DEBUG={is_debug}; ALLOWED_HOSTS+='{new_allowed_hosts_csv}'; CSRF_TRUSTED_ORIGINS+='{fixed_csrf_origins_csv}'; DEPLOY_DIR='{django_deploy_dir}'")

    try:
        with open(settings_file_path, 'r', encoding='utf-8') as f: lines = f.readlines()
    except Exception as e: log_py(f"BŁĄD KRYTYCZNY: Czytanie {settings_file_path}: {e}"); sys.exit(1)

    lines = update_setting_smart(lines, "DEBUG", "True" if is_debug else "False", "# Zmienione przez skrypt")

    final_allowed_hosts = set(['127.0.0.1', 'localhost']) 
    start_idx_ah, end_idx_ah = find_setting_block_indices(lines, "ALLOWED_HOSTS")
    if start_idx_ah != -1 and end_idx_ah != -1:
        block_str_ah = "".join(lines[start_idx_ah : end_idx_ah+1])
        try:
            eval_str = re.sub(r'ALLOWED_HOSTS\s*=\s*', '', block_str_ah, 1)
            existing_ah_list = eval(eval_str)
            if isinstance(existing_ah_list, list):
                final_allowed_hosts.update(existing_ah_list)
        except Exception as e_ah:
            log_py(f"Nie udało się sparsować (eval) ALLOWED_HOSTS: {e_ah}. Próba z regex.")
            match = re.search(r'ALLOWED_HOSTS\s*=\s*\[(.*?)\]', block_str_ah, re.DOTALL)
            if match:
                final_allowed_hosts.update([h.strip().strip("'\"") for h in match.group(1).split(',') if h.strip()])
    if new_allowed_hosts_csv:
        final_allowed_hosts.update([h.strip() for h in new_allowed_hosts_csv.split(',') if h.strip()])
    
    sorted_hosts = sorted(list(final_allowed_hosts))
    if len(sorted_hosts) > 2: 
        allowed_hosts_repr = "[\n"
        for h in sorted_hosts:
            allowed_hosts_repr += f"    {repr(h)},\n"
        allowed_hosts_repr += "]"
    elif not sorted_hosts: 
        allowed_hosts_repr = "[]"
    else: 
        allowed_hosts_repr = f"[{', '.join([repr(h) for h in sorted_hosts])}]"
    lines = update_setting_smart(lines, "ALLOWED_HOSTS", allowed_hosts_repr)
    
    final_csrf_origins = set()
    start_idx_csrf, end_idx_csrf = find_setting_block_indices(lines, "CSRF_TRUSTED_ORIGINS")
    if start_idx_csrf != -1 and end_idx_csrf != -1: 
        block_str_csrf = "".join(lines[start_idx_csrf : end_idx_csrf+1])
        try:
            eval_str_csrf = re.sub(r'CSRF_TRUSTED_ORIGINS\s*=\s*', '', block_str_csrf, 1)
            existing_csrf_list = eval(eval_str_csrf)
            if isinstance(existing_csrf_list, list):
                final_csrf_origins.update(existing_csrf_list)
        except Exception as e_csrf:
            log_py(f"Nie udało się sparsować (eval) CSRF_TRUSTED_ORIGINS: {e_csrf}. Próba z regex.")
            match = re.search(r'CSRF_TRUSTED_ORIGINS\s*=\s*\[(.*?)\]', block_str_csrf, re.DOTALL)
            if match:
                final_csrf_origins.update([o.strip().strip("'\"") for o in match.group(1).split(',') if o.strip()])
    if fixed_csrf_origins_csv:
        final_csrf_origins.update([o.strip() for o in fixed_csrf_origins_csv.split(',') if o.strip()])

    sorted_csrf_origins = sorted(list(final_csrf_origins))
    if len(sorted_csrf_origins) > 2: 
        csrf_origins_repr = "[\n"
        for o in sorted_csrf_origins:
            csrf_origins_repr += f"    {repr(o)},\n"
        csrf_origins_repr += "]"
    elif not sorted_csrf_origins:
        csrf_origins_repr = "[]"
    else:
        csrf_origins_repr = f"[{', '.join([repr(o) for o in sorted_csrf_origins])}]"
    lines = update_setting_smart(lines, "CSRF_TRUSTED_ORIGINS", csrf_origins_repr)

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
    
    start_idx_sfd, end_idx_sfd = find_setting_block_indices(lines, "STATICFILES_DIRS")
    if start_idx_sfd != -1: 
        block_str_sfd = "".join(lines[start_idx_sfd : end_idx_sfd+1])
        is_effectively_empty = True 
        match_brackets = re.search(r"STATICFILES_DIRS\s*=\s*\[(.*?)\]", block_str_sfd, re.DOTALL)
        match_parentheses = re.search(r"STATICFILES_DIRS\s*=\s*\((.*?)\)", block_str_sfd, re.DOTALL)
        content_inside = None
        if match_brackets: content_inside = match_brackets.group(1)
        elif match_parentheses: content_inside = match_parentheses.group(1)

        if content_inside is not None:
            cleaned_content = "".join(re.sub(r"#.*$", "", line_in_content).strip() for line_in_content in content_inside.splitlines())
            if cleaned_content: is_effectively_empty = False
        elif not re.match(r"STATICFILES_DIRS\s*=\s*(\[\]|\(\)\s*(#.*)?)", block_str_sfd.strip()): 
             is_effectively_empty = False 

        if is_effectively_empty:
            log_py(f"Ustawienie 'STATICFILES_DIRS' znalezione (linie {start_idx_sfd+1}-{end_idx_sfd+1}), ale jest/wydaje się puste. Ustawianie na '[]' z komentarzem.")
            lines = update_setting_smart(lines, "STATICFILES_DIRS", "[]", "# Potwierdzone/ustawione jako puste przez skrypt. W produkcji `collectstatic` używa `STATIC_ROOT`.", add_if_not_found=True) 
        else:
            log_py(f"Ustawienie 'STATICFILES_DIRS' znalezione (linie {start_idx_sfd+1}-{end_idx_sfd+1}) i zawiera wartości. Zachowywanie istniejącej konfiguracji.")
    else:
        log_py("Ustawienie 'STATICFILES_DIRS' nie zostało znalezione. Skrypt nie będzie go dodawał.")

    imports_to_add = []
    if ("os.path.join(" in static_root_val or "os.path.join(" in media_root_val) and not any(re.match(r"^\s*import\s+os", line) for line in lines):
        imports_to_add.append("import os\n")
    if ("BASE_DIR / " in static_root_val or "BASE_DIR / " in media_root_val) and not any(re.match(r"^\s*from\s+pathlib\s+import\s+Path", line) for line in lines):
        imports_to_add.append("from pathlib import Path\n")

    if imports_to_add:
        import_insertion_point = 0
        future_import_found = False
        for i, line_content in enumerate(lines):
            stripped_line = line_content.strip()
            if stripped_line.startswith("from __future__ import"):
                import_insertion_point = i + 1 
                future_import_found = True
                continue 
            if not future_import_found and not stripped_line.startswith('#') and stripped_line != "" and not stripped_line.startswith("'''") and not stripped_line.startswith('"""'):
                import_insertion_point = i
                break 
        
        if future_import_found:
             while import_insertion_point < len(lines) and (lines[import_insertion_point].strip() == "" or lines[import_insertion_point].strip().startswith("#")):
                import_insertion_point += 1
        elif import_insertion_point == 0 and (lines[0].strip().startswith('#') or lines[0].strip() == ""):
             pass 
        
        for imp_line in reversed(imports_to_add): 
            lines.insert(import_insertion_point, imp_line)
            log_py(f"Dodano '{imp_line.strip()}'")
        if import_insertion_point + len(imports_to_add) < len(lines) and \
           lines[import_insertion_point + len(imports_to_add)].strip() != "":
            lines.insert(import_insertion_point + len(imports_to_add), "\n")

    try:
        with open(settings_file_path, 'w', encoding='utf-8') as f: f.writelines(lines)
        log_py(f"Pomyślnie zaktualizowano plik: {settings_file_path}")
    except Exception as e: log_py(f"BŁĄD KRYTYCZNY: Zapis {settings_file_path}: {e}"); sys.exit(1)

if __name__ == "__main__":
    main()
# Koniec settings_updater.py
EOF_PYTHON_SETTINGS_UPDATER
chmod +x "$SETTINGS_UPDATER_PY_SCRIPT_PATH"

DOMAINS_FOR_PY_ALLOWED_HOSTS="$MAIN_DOMAIN"
AUTO_WWW_DOMAIN=""
if [ -n "$WWW_ALIAS_DOMAIN" ]; then
    DOMAINS_FOR_PY_ALLOWED_HOSTS="${DOMAINS_FOR_PY_ALLOWED_HOSTS},${WWW_ALIAS_DOMAIN}"
elif [[ "$MAIN_DOMAIN" != www.* ]]; then
    AUTO_WWW_DOMAIN="www.${MAIN_DOMAIN}"
    DOMAINS_FOR_PY_ALLOWED_HOSTS="${DOMAINS_FOR_PY_ALLOWED_HOSTS},${AUTO_WWW_DOMAIN}"
fi

FIXED_CSRF_ORIGINS_LIST=()
FIXED_CSRF_ORIGINS_LIST+=("https://${MAIN_DOMAIN}")
FIXED_CSRF_ORIGINS_LIST+=("http://${MAIN_DOMAIN}")

if [ -n "$AUTO_WWW_DOMAIN" ]; then 
    FIXED_CSRF_ORIGINS_LIST+=("https://${AUTO_WWW_DOMAIN}")
    FIXED_CSRF_ORIGINS_LIST+=("http://${AUTO_WWW_DOMAIN}")
elif [ -n "$WWW_ALIAS_DOMAIN" ]; then 
    FIXED_CSRF_ORIGINS_LIST+=("https://${WWW_ALIAS_DOMAIN}")
    FIXED_CSRF_ORIGINS_LIST+=("http://${WWW_ALIAS_DOMAIN}")
fi
FIXED_CSRF_ORIGINS_FOR_PY=$(IFS=,; echo "${FIXED_CSRF_ORIGINS_LIST[*]}")
log_debug "FIXED_CSRF_ORIGINS_FOR_PY ustawione na: $FIXED_CSRF_ORIGINS_FOR_PY"


log_msg "Konfigurowanie pliku settings.py ($DJANGO_SETTINGS_PY_PATH)..."
if ! "$PYTHON_EXEC_PATH" "$SETTINGS_UPDATER_PY_SCRIPT_PATH" \
    "$DJANGO_SETTINGS_PY_PATH" \
    "$DOMAINS_FOR_PY_ALLOWED_HOSTS" \
    "$FIXED_CSRF_ORIGINS_FOR_PY" \
    "$DEPLOY_DIR" \
    "$DJANGO_PROJECT_NAME" \
    "false"; then 
    log_error "Skrypt Pythona ($SETTINGS_UPDATER_PY_SCRIPT_PATH) do aktualizacji settings.py zakończył się błędem."
    exit 1
fi
log_msg "Plik settings.py skonfigurowany."

# --- POCZĄTEK: Dodatkowe sprawdzanie i instalacja brakujących zależności ---
declare -A MISSING_DEPENDENCIES
MISSING_DEPENDENCIES["daphne"]="daphne"
MISSING_DEPENDENCIES["background_task"]="django-background-tasks"
# Można tu dodać więcej mapowań 'nazwa_modułu_w_settings': 'nazwa_pakietu_pip'

for module_name in "${!MISSING_DEPENDENCIES[@]}"; do
    package_name="${MISSING_DEPENDENCIES[$module_name]}"
    log_msg "Sprawdzanie, czy moduł '$module_name' (pakiet '$package_name') jest wymagany i zainstalowany..."
    if grep -v "^\s*#" "$DJANGO_SETTINGS_PY_PATH" | grep -q -E "['\"]${module_name}['\"]"; then
        log_msg "Moduł '$module_name' znaleziono w pliku $DJANGO_SETTINGS_PY_PATH."
        if ! "$PIP_EXEC_PATH" show "$package_name" &> /dev/null; then
            log_warn "Pakiet '$package_name' (dla modułu '$module_name') wydaje się być wymagany, ale nie jest zainstalowany. Próba instalacji..."
            if "$PIP_EXEC_PATH" install "$package_name"; then
                log_msg "Pomyślnie zainstalowano '$package_name'."
            else
                log_error "Nie udało się zainstalować '$package_name'. Jeśli jest wymagany, dodaj go do requirements.txt. Przerywam."
                exit 1
            fi
        else
            log_msg "Pakiet '$package_name' jest już zainstalowany w środowisku wirtualnym."
        fi
    else
        log_msg "Moduł '$module_name' nie znaleziono w $DJANGO_SETTINGS_PY_PATH (lub jest zakomentowany / nie jest bezpośrednio listowany jako string). Pomijanie dodatkowej instalacji '$package_name'."
    fi
done
# --- KONIEC: Dodatkowe sprawdzanie i instalacja brakujących zależności ---

log_msg "Tworzenie wymaganych katalogów i nadawanie uprawnień..."
# Katalogi dla plików statycznych i mediów
mkdir -p "${DEPLOY_DIR}/staticfiles_collected"
mkdir -p "${DEPLOY_DIR}/mediafiles"
chown -R "${DEPLOY_USER}:${DEPLOY_GROUP}" "${DEPLOY_DIR}/staticfiles_collected"
chown -R "${DEPLOY_USER}:${DEPLOY_GROUP}" "${DEPLOY_DIR}/mediafiles"

# Katalog logów na poziomie DEPLOY_DIR (ogólny) - for /var/www/django/logs/background_tasks.log
GENERAL_LOGS_DIR="${DEPLOY_DIR}/logs"
log_msg "Tworzenie ogólnego katalogu logów: ${GENERAL_LOGS_DIR}"
mkdir -p "$GENERAL_LOGS_DIR"
chown "${DEPLOY_USER}:${DEPLOY_GROUP}" "$GENERAL_LOGS_DIR"
chmod 775 "$GENERAL_LOGS_DIR" # Owner:rwx, Group:rwx, Other:r-x

# Katalog logów specyficzny dla aplikacji (jeśli settings.py używa BASE_DIR/logs/...)
if [ -n "$DJANGO_PROJECT_MODULE_DIR_PATH" ] && [ -d "$DJANGO_PROJECT_MODULE_DIR_PATH" ]; then
    APP_SPECIFIC_LOGS_DIR="${DJANGO_PROJECT_MODULE_DIR_PATH}/logs"
    if [ "$APP_SPECIFIC_LOGS_DIR" != "$GENERAL_LOGS_DIR" ]; then 
        log_msg "Tworzenie katalogu logów specyficznego dla aplikacji: ${APP_SPECIFIC_LOGS_DIR}"
        mkdir -p "$APP_SPECIFIC_LOGS_DIR"
        chown "${DEPLOY_USER}:${DEPLOY_GROUP}" "$APP_SPECIFIC_LOGS_DIR"
        chmod 775 "$APP_SPECIFIC_LOGS_DIR"
    fi
else
    log_warn "Nie można było określić DJANGO_PROJECT_MODULE_DIR_PATH lub katalog nie istnieje. Pomijanie tworzenia specyficznego katalogu logów aplikacji."
fi

log_msg "Uruchamianie poleceń zarządzania Django..."
cd "$DEPLOY_DIR" 

log_msg "Uruchamianie collectstatic..."
if "$PYTHON_EXEC_PATH" manage.py collectstatic --noinput --clear; then
    log_msg "Polecenie collectstatic zakończone pomyślnie."
else
    log_error "Polecenie collectstatic nie powiodło się. Sprawdź logi powyżej.";
    "$PYTHON_EXEC_PATH" manage.py collectstatic --noinput --clear >> "$DEPLOY_LOG_FILE" 2>&1 || true ;
    exit 1;
fi

log_msg "Uruchamianie migracji bazy danych..."
if "$PYTHON_EXEC_PATH" manage.py migrate --noinput; then
    log_msg "Migracje bazy danych zakończone pomyślnie."
else
    log_error "Migracje Django nie powiodły się. Sprawdź logi powyżej."; exit 1;
fi

log_msg "Konfigurowanie usługi Gunicorn..."
cat > "$GUNICORN_SERVICE_FILE" << EOF
[Unit]
Description=Gunicorn daemon for Django project at $DEPLOY_DIR
Requires=${GUNICORN_SERVICE_RUNTIME_DIR_NAME}.socket
After=network.target ${GUNICORN_SERVICE_RUNTIME_DIR_NAME}.socket

[Service]
User=$DEPLOY_USER
Group=$DEPLOY_GROUP
WorkingDirectory=$DEPLOY_DIR
ExecStart=${PYTHON_EXEC_PATH} ${PYTHON_VENV_PATH}/bin/gunicorn --access-logfile - --error-logfile - --workers 3 --bind unix:${GUNICORN_SOCKET_PATH} ${DJANGO_PROJECT_NAME}.wsgi:application
Restart=always
RestartSec=5s 

[Install]
WantedBy=multi-user.target
EOF

GUNICORN_SOCKET_CONTENT="[Unit]
Description=gunicorn socket for ${DJANGO_PROJECT_NAME}

[Socket]
ListenStream=${GUNICORN_SOCKET_PATH}
SocketUser=$DEPLOY_USER
SocketGroup=$DEPLOY_GROUP
SocketMode=0660 

[Install]
WantedBy=sockets.target
"
CURRENT_GUNICORN_SOCKET_CONTENT=""
if [ -f "$GUNICORN_SOCKET_SYSTEMD_FILE" ]; then
    CURRENT_GUNICORN_SOCKET_CONTENT=$(cat "$GUNICORN_SOCKET_SYSTEMD_FILE")
fi

if [ "$CURRENT_GUNICORN_SOCKET_CONTENT" != "$GUNICORN_SOCKET_CONTENT" ]; then
    log_msg "Tworzenie lub aktualizowanie pliku ${GUNICORN_SERVICE_RUNTIME_DIR_NAME}.socket..."
    echo "$GUNICORN_SOCKET_CONTENT" > "$GUNICORN_SOCKET_SYSTEMD_FILE"
    systemctl daemon-reload 
    systemctl enable "${GUNICORN_SERVICE_RUNTIME_DIR_NAME}.socket"
else
    log_msg "Plik socketu Gunicorn (${GUNICORN_SOCKET_SYSTEMD_FILE}) jest aktualny."
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

    location = /favicon.ico { access_log off; log_not_found off; alias ${DEPLOY_DIR}/staticfiles_collected/favicon.ico; } 
    location = /robots.txt { access_log off; log_not_found off; alias ${DEPLOY_DIR}/staticfiles_collected/robots.txt; } 

    location /static/ {
        alias ${DEPLOY_DIR}/staticfiles_collected/;
        expires 30d; 
        access_log off; 
    }
    location /media/ {
        alias ${DEPLOY_DIR}/mediafiles/;
        expires 30d; 
        access_log off; 
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
proxy_redirect off;
EOF_PROXY_PARAMS
fi

log_msg "Plik konfiguracyjny Nginx ($NGINX_CONF_FILE_PATH) utworzony/zaktualizowany."
SYMLINK_TARGET="$NGINX_SITES_ENABLED_DIR/$NGINX_CONF_FILENAME"
if [ -L "$SYMLINK_TARGET" ] && [ "$(readlink -f "$SYMLINK_TARGET")" != "$NGINX_CONF_FILE_PATH" ]; then
    log_warn "Usuwanie starego, niepoprawnego dowiązania Nginx: $SYMLINK_TARGET";
    rm -f "$SYMLINK_TARGET";
fi
if [ ! -L "$SYMLINK_TARGET" ]; then
    ln -s "$NGINX_CONF_FILE_PATH" "$SYMLINK_TARGET";
    log_msg "Utworzono dowiązanie symboliczne Nginx: $SYMLINK_TARGET -> $NGINX_CONF_FILE_PATH";
fi

log_msg "Testowanie konfiguracji Nginx..."
if nginx -t; then
    log_msg "Konfiguracja Nginx poprawna.";
else
    log_error "Błąd konfiguracji Nginx. Sprawdź powyższe komunikaty.";
    nginx -t >> "$DEPLOY_LOG_FILE" 2>&1 || true
    exit 1;
fi

log_msg "Przeładowywanie demona systemd (jeśli konieczne)..."
systemctl daemon-reload

# --- POCZĄTEK: Zapewnienie dostępności pliku logu dla Gunicorn ---
# Zakładamy, że jeśli LOGGING jest skonfigurowany dla background_task, to będzie to w /var/www/django/logs/
# lub /var/www/django/nazwa_projektu/logs/
# Skrypt już tworzy te katalogi z odpowiednimi uprawnieniami.
# Ta sekcja dodatkowo upewnia się, że konkretny plik logu jest dostępny.
# Jeśli Twój projekt używa innej ścieżki, musisz ją dostosować tutaj.
BG_TASK_LOG_FILE_PATH_OPTION1="${DEPLOY_DIR}/logs/background_tasks.log"
BG_TASK_LOG_FILE_PATH_OPTION2=""
if [ -n "$DJANGO_PROJECT_MODULE_DIR_PATH" ]; then
    BG_TASK_LOG_FILE_PATH_OPTION2="${DJANGO_PROJECT_MODULE_DIR_PATH}/logs/background_tasks.log"
fi

TARGET_BG_TASK_LOG_FILE=""

# Sprawdź, która konfiguracja logowania jest prawdopodobnie używana
# (to jest heurystyka, idealnie konfiguracja LOGGING powinna być bardziej przewidywalna)
if [ -f "${DJANGO_SETTINGS_PY_PATH}" ]; then
    if grep -q "os.path.join(BASE_DIR, 'logs', 'background_tasks.log')" "${DJANGO_SETTINGS_PY_PATH}" && [ -n "$BG_TASK_LOG_FILE_PATH_OPTION2" ]; then
        TARGET_BG_TASK_LOG_FILE="$BG_TASK_LOG_FILE_PATH_OPTION2"
        log_msg "Wykryto konfigurację logu background_tasks w katalogu projektu: ${TARGET_BG_TASK_LOG_FILE}"
    elif grep -q "'filename': '${DEPLOY_DIR}/logs/background_tasks.log'" "${DJANGO_SETTINGS_PY_PATH}"; then
        TARGET_BG_TASK_LOG_FILE="$BG_TASK_LOG_FILE_PATH_OPTION1"
        log_msg "Wykryto konfigurację logu background_tasks w głównym katalogu wdrożenia: ${TARGET_BG_TASK_LOG_FILE}"
    elif grep -q "'background_task_file'" "${DJANGO_SETTINGS_PY_PATH}"; then # Jeśli handler jest, ale ścieżka nie jest jasna, spróbuj domyślną
        TARGET_BG_TASK_LOG_FILE="$BG_TASK_LOG_FILE_PATH_OPTION1"
        log_warn "Nie można jednoznacznie określić ścieżki logu background_tasks. Próba z domyślną: ${TARGET_BG_TASK_LOG_FILE}"
    fi
fi


if [ -n "$TARGET_BG_TASK_LOG_FILE" ]; then
    BG_TASK_LOG_DIR=$(dirname "$TARGET_BG_TASK_LOG_FILE")

    log_msg "Zapewnianie dostępności pliku logu ${TARGET_BG_TASK_LOG_FILE} dla użytkownika ${DEPLOY_USER}..."

    if [ ! -d "$BG_TASK_LOG_DIR" ]; then
        log_warn "Katalog logów ${BG_TASK_LOG_DIR} nie istniał. Próba utworzenia..."
        mkdir -p "$BG_TASK_LOG_DIR"
        chown "${DEPLOY_USER}:${DEPLOY_GROUP}" "$BG_TASK_LOG_DIR"
        chmod 775 "$BG_TASK_LOG_DIR"
    fi
    
    # Jeśli plik logu istnieje i należy do root, zmień właściciela
    if [ -f "$TARGET_BG_TASK_LOG_FILE" ]; then
        if [ "$(stat -c '%U' "$TARGET_BG_TASK_LOG_FILE")" = "root" ]; then
            log_warn "Plik logu ${TARGET_BG_TASK_LOG_FILE} istnieje i należy do root. Zmieniam właściciela na ${DEPLOY_USER}:${DEPLOY_GROUP}."
            chown "${DEPLOY_USER}:${DEPLOY_GROUP}" "$TARGET_BG_TASK_LOG_FILE"
        fi
    fi

    log_msg "Próba utworzenia/dotknięcia pliku logu: ${TARGET_BG_TASK_LOG_FILE} jako użytkownik ${DEPLOY_USER}"
    if sudo -u "$DEPLOY_USER" touch "$TARGET_BG_TASK_LOG_FILE"; then
        log_msg "Pomyślnie 'touch' dla pliku ${TARGET_BG_TASK_LOG_FILE} jako ${DEPLOY_USER}."
        chown "${DEPLOY_USER}:${DEPLOY_GROUP}" "$TARGET_BG_TASK_LOG_FILE" 
        chmod 664 "$TARGET_BG_TASK_LOG_FILE" 
        log_msg "Ustawiono właściciela i uprawnienia dla ${TARGET_BG_TASK_LOG_FILE}."
    else
        log_error "Nie udało się 'touch' dla pliku ${TARGET_BG_TASK_LOG_FILE} jako ${DEPLOY_USER}."
        log_error "Sprawdź uprawnienia katalogu: $(ls -ld "$BG_TASK_LOG_DIR")"
        if [ -e "$TARGET_BG_TASK_LOG_FILE" ]; then 
            log_error "Sprawdź uprawnienia istniejącego pliku: $(ls -l "$TARGET_BG_TASK_LOG_FILE")"
        fi
    fi
else
    log_warn "Nie udało się zidentyfikować docelowego pliku logu dla 'background_task_file'. Pomijanie proaktywnego tworzenia pliku logu."
    log_warn "Jeśli Gunicorn nadal ma problemy z logowaniem, sprawdź konfigurację LOGGING w settings.py i uprawnienia do odpowiednich plików/katalogów."
fi
# --- KONIEC: Zapewnienie dostępności pliku logu ---

log_msg "Włączanie i restartowanie usług Gunicorn..."
systemctl enable "${GUNICORN_SERVICE_RUNTIME_DIR_NAME}.socket"
systemctl restart "${GUNICORN_SERVICE_RUNTIME_DIR_NAME}.socket"
systemctl enable gunicorn_django.service
systemctl restart gunicorn_django.service

log_msg "Czekam 5 sekund na Gunicorn..."
sleep 5 
if ! systemctl is-active --quiet gunicorn_django.service; then
    log_error "Gunicorn nie uruchomił się prawidłowo."
    log_error "Sprawdź status: sudo systemctl status gunicorn_django.service"
    log_error "Sprawdź logi: sudo journalctl -u gunicorn_django.service -n 50 --no-pager"
    exit 1;
fi
if ! systemctl is-active --quiet "${GUNICORN_SERVICE_RUNTIME_DIR_NAME}.socket"; then
    log_error "Socket Gunicorna (${GUNICORN_SERVICE_RUNTIME_DIR_NAME}.socket) nie jest aktywny."
    log_error "Sprawdź status: sudo systemctl status ${GUNICORN_SERVICE_RUNTIME_DIR_NAME}.socket"
    exit 1;
fi
log_msg "Gunicorn pomyślnie (re)startowany i socket jest aktywny."

log_msg "Restartowanie usługi Nginx..."
systemctl restart nginx.service
if ! systemctl is-active --quiet nginx.service; then
    log_error "Nginx nie uruchomił się prawidłowo."
    log_error "Sprawdź status: sudo systemctl status nginx.service"
    log_error "Sprawdź logi: sudo journalctl -u nginx.service -n 50 --no-pager"
    exit 1;
fi
log_msg "Nginx pomyślnie zrestartowany."

chown -R "${DEPLOY_USER}:${DEPLOY_GROUP}" "${DEPLOY_DIR}"
chmod -R o-rwx,g-w "${DEPLOY_DIR}" 
find "${DEPLOY_DIR}" -type d -exec chmod g+s {} \; 

log_msg "Wdrożenie zakończone pomyślnie!"
log_msg "Aplikacja powinna być dostępna pod adresem: http://$MAIN_DOMAIN"
if [ -n "$AUTO_WWW_DOMAIN" ]; then log_msg "oraz http://$AUTO_WWW_DOMAIN"; fi
if [ -n "$WWW_ALIAS_DOMAIN" ]; then log_msg "oraz http://$WWW_ALIAS_DOMAIN"; fi
log_msg "Sprawdź logi wdrożenia w: $DEPLOY_LOG_FILE"

exit 0
