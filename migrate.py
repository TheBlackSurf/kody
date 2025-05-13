#!/usr/bin/env python3

import requests
import os
import subprocess
import shutil
import json
import sys
import time
import math # Do wskaźnika postępu
import argparse
import re # Do operacji na stringach (regex)

# --- Konfiguracja ---
WP_ROOT_DIR = "/var/www/html/wp"
BACKUP_DIR_NAME = "izolka-backups"
WP_CONTENT_DIR_NAME = "wp-content"
TEMP_DIR_NAME = "izolka-migration-temp"
FULL_TEMP_DIR = os.path.join(WP_ROOT_DIR, TEMP_DIR_NAME)
FULL_TEMP_WP_CONFIG_PATH = os.path.join(FULL_TEMP_DIR, "wp-config.php.original_target")
FINAL_ZIP_FILE = "backup_finalny.zip"
FULL_FINAL_ZIP_PATH = os.path.join(FULL_TEMP_DIR, FINAL_ZIP_FILE)
CHUNK_SIZE = 5242880 # 5MB
WP_CLI_BIN = "wp" # Domyślna nazwa, zostanie zweryfikowana i potencjalnie zaktualizowana w main()
WP_CLI_FLAGS = ["--allow-root"]
WEB_USER = "www-data"
WEB_GROUP = "www-data"

# --- Funkcje pomocnicze ---

def run_command(command, check=True, **kwargs):
    print(f"-> Uruchamiam: {' '.join(command)}")
    effective_kwargs = kwargs.copy()
    if 'capture_output' not in effective_kwargs:
        effective_kwargs['capture_output'] = True
    if 'text' not in effective_kwargs:
        effective_kwargs['text'] = True
    original_check = check
    try:
        result = subprocess.run(command, check=False, **effective_kwargs)
        if original_check and result.returncode != 0:
            raise subprocess.CalledProcessError(
                result.returncode, command, output=result.stdout, stderr=result.stderr
            )
        if not original_check and result.returncode != 0:
            stderr_output = result.stderr.strip() if result.stderr else ""
            stdout_output = result.stdout.strip() if result.stdout else ""

            is_search_replace_no_change = (
                len(command) > 2 and # Upewnij się, że command ma wystarczająco dużo elementów
                command[1:3] == ["search-replace", command[2]] and
                ("No tables found to replace" in stderr_output or "No values changed" in stderr_output or "0 replacements" in stdout_output) # Dodano "0 replacements"
            )
            is_db_create_exists = (
                len(command) > 2 and command[1:2] == ["db"] and command[2] in ["create"] and
                result.stderr and "database exists" in result.stderr.lower()
            )
            is_cache_flush_not_found = (
                len(command) > 1 and command[1:3] == ["cache", "flush"] and
                result.stderr and ("does not exist" in result.stderr.lower() or "isn't an object cache" in result.stderr.lower()) # Błąd, gdy nie ma cache do wyczyszczenia
            )


            if not (is_search_replace_no_change or is_db_create_exists or is_cache_flush_not_found):
                 print(f"Ostrzeżenie: Komenda '{' '.join(command)}' zwróciła kod wyjścia {result.returncode}", file=sys.stderr)
                 if stdout_output: print(f"Stdout (Ostrzeżenie):\n{stdout_output}", file=sys.stderr)
                 if stderr_output: print(f"Stderr (Ostrzeżenie):\n{stderr_output}", file=sys.stderr)
            elif is_search_replace_no_change:
                 print(f"  Komenda '{' '.join(command[:3])}...' zakończona (brak zmian lub brak tabel).")
            elif is_db_create_exists:
                print(f"  Informacja: Baza danych już istniała (komunikat od 'wp db create').")
            elif is_cache_flush_not_found:
                print(f"  Informacja: Nie znaleziono obiektu cache do wyczyszczenia lub mechanizm nie jest aktywny.")


        return result
    except subprocess.CalledProcessError as e:
        print(f"Błąd: Komenda '{' '.join(command)}' zwróciła kod wyjścia {e.returncode}", file=sys.stderr)
        if e.stdout and e.stdout.strip(): print(f"Stdout (Błąd):\n{e.stdout.strip()}", file=sys.stderr)
        if e.stderr and e.stderr.strip(): print(f"Stderr (Błąd):\n{e.stderr.strip()}", file=sys.stderr)
        return None
    except FileNotFoundError:
        print(f"Błąd: Komenda '{command[0]}' nie znaleziona. Sprawdź czy jest zainstalowana i czy jest w PATH.", file=sys.stderr)
        return None
    except PermissionError as e:
        print(f"Błąd uprawnień podczas próby uruchomienia '{command[0]}': {e}", file=sys.stderr)
        return None
    except Exception as e:
        print(f"Wystąpił nieoczekiwany błąd systemowy podczas uruchamiania komendy: {e}", file=sys.stderr)
        return None


def print_progress(current, total, prefix='Pobieranie:'):
    if total == 0: percent, done = 100, 50
    else:
        done = math.floor(50 * current / total)
        percent = math.floor(100 * current / total)
    sys.stdout.write(f"\r{prefix} [{'-' * done}{' ' * (50 - done)}] {percent}%")
    sys.stdout.flush()

def get_file_size(filepath):
    try: return os.path.getsize(filepath)
    except FileNotFoundError: return None
    except Exception as e:
        print(f"\nBłąd: Nie można pobrać rozmiaru pliku '{filepath}': {e}", file=sys.stderr)
        return None

def cleanup_temp_dir():
    if os.path.exists(FULL_TEMP_DIR):
        try:
            shutil.rmtree(FULL_TEMP_DIR)
            print(f"Katalog tymczasowy {FULL_TEMP_DIR} usunięty.")
        except Exception as e:
            print(f"Ostrzeżenie: Nie udało się usunąć katalogu tymczasowego '{FULL_TEMP_DIR}': {e}", file=sys.stderr)
    else:
        print(f"Katalog tymczasowy {FULL_TEMP_DIR} nie istniał, nie ma czego sprzątać.")

def get_table_prefix_from_config(wp_config_path):
    """Odczytuje $table_prefix z pliku wp-config.php."""
    try:
        with open(wp_config_path, 'r', encoding='utf-8') as f:
            content = f.read()
        match = re.search(r"\$table_prefix\s*=\s*'([^']+)';", content)
        if match:
            return match.group(1)
        else:
            print(f"Nie znaleziono definicji $table_prefix w {wp_config_path}", file=sys.stderr)
            return None
    except Exception as e:
        print(f"Błąd odczytu prefixu z {wp_config_path}: {e}", file=sys.stderr)
        return None

def update_table_prefix_in_config(wp_config_path, new_prefix):
    """Aktualizuje $table_prefix w pliku wp-config.php."""
    try:
        with open(wp_config_path, 'r', encoding='utf-8') as f:
            lines = f.readlines()

        updated_lines = []
        prefix_updated = False
        for line in lines:
            if line.strip().startswith("$table_prefix"):
                updated_lines.append(f"$table_prefix = '{new_prefix}';\n")
                prefix_updated = True
            else:
                updated_lines.append(line)

        if prefix_updated:
            with open(wp_config_path, 'w', encoding='utf-8') as f:
                f.writelines(updated_lines)
            print(f"Zaktualizowano $table_prefix na '{new_prefix}' w {wp_config_path}")
            return True
        else:
            print(f"Nie znaleziono linii $table_prefix do aktualizacji w {wp_config_path}", file=sys.stderr)
            return False

    except Exception as e:
        print(f"Błąd aktualizacji prefixu w {wp_config_path}: {e}", file=sys.stderr)
        return False


# --- Główny skrypt ---
def main():
    parser = argparse.ArgumentParser(description="Skrypt migracji WordPressa z backupu Izolka Migrate.")
    parser.add_argument("source_url", help="URL strony źródłowej (bez http/https), np. cbmc.pl")
    parser.add_argument("api_key", help="Klucz API wtyczki Izolka Migrate ze strony źródłowej.")
    args = parser.parse_args()

    SOURCE_DOMAIN = args.source_url
    API_KEY = args.api_key
    SOURCE_BASE_URL = f"https://{SOURCE_DOMAIN}"
    TRIGGER_ENDPOINT = f"{SOURCE_BASE_URL}/wp-json/izolka-migrate/v1/trigger"
    DOWNLOAD_ENDPOINT = f"{SOURCE_BASE_URL}/wp-json/izolka-migrate/v1/download"

    exit_code = 0
    NEW_URL = ""

    global WP_CLI_BIN # Deklarujemy zamiar modyfikacji globalnej zmiennej

    try:
        print(f"Przechodzenie do katalogu WordPressa docelowego: {WP_ROOT_DIR}")
        if not os.path.isdir(WP_ROOT_DIR):
             raise Exception(f"Katalog '{WP_ROOT_DIR}' nie istnieje lub nie jest katalogiem.")
        os.chdir(WP_ROOT_DIR)
        print(f"Jesteś w katalogu: {os.getcwd()}")

        print("Sprawdzanie wymaganych narzędzi...")
        if not shutil.which("unzip"):
            raise Exception("Wymagany 'unzip' nie jest zainstalowany.")

        # --- Logika znajdowania WP-CLI ---
        wp_cli_initial_name = "wp"
        found_wp_cli_path = shutil.which(wp_cli_initial_name)

        if found_wp_cli_path:
            WP_CLI_BIN = found_wp_cli_path
            print(f"Znaleziono WP-CLI w PATH: {WP_CLI_BIN}")
        else:
            print(f"WP-CLI ('{wp_cli_initial_name}') nie znaleziono w standardowym PATH.")
            common_direct_path = "/usr/local/bin/wp"
            if os.path.exists(common_direct_path) and os.access(common_direct_path, os.X_OK):
                print(f"Znaleziono WP-CLI pod bezpośrednią ścieżką: {common_direct_path}. Używam tej ścieżki.")
                WP_CLI_BIN = common_direct_path
            else:
                print(f"WP-CLI nie znaleziono również pod {common_direct_path}.")
                current_env_path = os.environ.get('PATH', '')
                usr_local_bin_dir = '/usr/local/bin'

                if usr_local_bin_dir not in current_env_path.split(os.pathsep):
                    print(f"Katalog '{usr_local_bin_dir}' nie znajduje się w aktualnym PATH. Próbuję dodać go tymczasowo.")
                    os.environ['PATH'] = f"{usr_local_bin_dir}{os.pathsep}{current_env_path}"
                    print(f"Nowy (tymczasowy) PATH: {os.environ['PATH']}")
                    
                    found_wp_cli_path_after_mod = shutil.which(wp_cli_initial_name)
                    if found_wp_cli_path_after_mod:
                        WP_CLI_BIN = found_wp_cli_path_after_mod
                        print(f"Znaleziono WP-CLI ('{WP_CLI_BIN}') po modyfikacji PATH.")
                    elif os.path.exists(common_direct_path) and os.access(common_direct_path, os.X_OK):
                        # Fallback jeśli shutil.which nadal nie działa, ale plik istnieje
                        print(f"shutil.which nadal nie znajduje '{wp_cli_initial_name}' po modyfikacji PATH, ale {common_direct_path} istnieje. Używam bezpośredniej ścieżki: {common_direct_path}")
                        WP_CLI_BIN = common_direct_path
                    else:
                        raise Exception(f"WP-CLI ('{wp_cli_initial_name}') nie jest zainstalowane lub nie jest wykonywalne. Próbowano standardowy PATH, bezpośrednią ścieżkę '{common_direct_path}' oraz modyfikację PATH (dodanie '{usr_local_bin_dir}').")
                else:
                    # /usr/local/bin był już w PATH, ale shutil.which("wp") zawiódł, a common_direct_path nie istnieje/nie jest wykonywalny
                    raise Exception(f"WP-CLI ('{wp_cli_initial_name}') nie jest zainstalowane lub nie jest wykonywalne. Katalog '{usr_local_bin_dir}' jest w PATH, ale komenda nie została znaleziona, a bezpośrednia ścieżka '{common_direct_path}' nie działa.")
        # --- Koniec logiki znajdowania WP-CLI ---

        wp_version_result = run_command([WP_CLI_BIN, "--version"] + WP_CLI_FLAGS)
        if wp_version_result is None or wp_version_result.returncode != 0:
            error_msg = f"Nie można uruchomić WP-CLI ({WP_CLI_BIN}). "
            if WP_CLI_BIN == common_direct_path and not (os.path.exists(WP_CLI_BIN) and os.access(WP_CLI_BIN, os.X_OK)):
                 error_msg += f"Plik '{WP_CLI_BIN}' nie istnieje lub nie ma uprawnień do wykonania. "
            error_msg += f"Sprawdź instalację WP-CLI, uprawnienia i konfigurację PATH. Kod błędu: {wp_version_result.returncode if wp_version_result else 'Brak obiektu result'}."
            raise Exception(error_msg)
        if wp_version_result.stdout: print(f"Wersja WP-CLI: {wp_version_result.stdout.strip()}")
        print("Narzędzia OK.")


        WP_CONFIG_DEST_PATH_IN_ROOT = os.path.join(WP_ROOT_DIR, "wp-config.php")
        if not all(os.path.exists(p) for p in [WP_CONFIG_DEST_PATH_IN_ROOT, "wp-admin", "wp-includes"]):
            raise Exception(f"Katalog '{WP_ROOT_DIR}' nie wygląda na główny katalog WordPressa (brakuje wp-config.php, wp-admin lub wp-includes).")
        print("Struktura katalogu WordPressa docelowego OK.")

        print(f"\n!!! OSTRZEŻENIE !!!")
        print(f"Ten skrypt POBIERZE backup z {SOURCE_BASE_URL} i CAŁKOWICIE nadpisze pliki i bazę danych")
        print(f"w docelowej instalacji WordPressa ({WP_ROOT_DIR}).")
        print(f"Jest to operacja DESTRUKCYJNA i NIEODWRACALNA.")
        print(f"Rozpoczynanie automatycznej migracji...\n")

        print(f"Przygotowanie tymczasowego katalogu: {FULL_TEMP_DIR}")
        if os.path.exists(FULL_TEMP_DIR): shutil.rmtree(FULL_TEMP_DIR)
        os.makedirs(FULL_TEMP_DIR)
        print("Katalog tymczasowy OK.")

        print(f"Wywoływanie backupu na stronie źródłowej: {TRIGGER_ENDPOINT}")
        headers = {"X-API-Key": API_KEY}
        try:
            trigger_response = requests.post(TRIGGER_ENDPOINT, headers=headers, timeout=60)
            trigger_response.raise_for_status() # Podniesie wyjątek dla kodów 4xx/5xx
            trigger_data = trigger_response.json()
        except requests.exceptions.RequestException as e:
            raise Exception(f"Błąd połączenia lub HTTP podczas wywoływania triggera: {e}")
        except json.JSONDecodeError:
            raise Exception(f"Nie udało się zdekodować odpowiedzi JSON z triggera. Odpowiedź: {trigger_response.text}")

        if not trigger_data.get('success'):
            raise Exception(f"Błąd triggera: {trigger_data.get('message', 'Nieznany błąd')}")
        backup_filename = trigger_data['filename']
        backup_filesize = int(trigger_data['file_size'])
        print(f"Informacje o backupie: Plik: {backup_filename}, Rozmiar: {backup_filesize} bajtów.")

        print(f"Pobieranie backupu z: {DOWNLOAD_ENDPOINT}")
        downloaded_size = 0
        if backup_filesize == 0:
            with open(FULL_FINAL_ZIP_PATH, 'wb') as f: pass
            print_progress(0,0)
            print("\nPusty plik utworzony (rozmiar 0).")
        else:
            try:
                with requests.get(DOWNLOAD_ENDPOINT, headers=headers, stream=True, timeout=300) as r:
                    r.raise_for_status()
                    with open(FULL_FINAL_ZIP_PATH, 'wb') as f:
                        for chunk in r.iter_content(chunk_size=CHUNK_SIZE):
                            f.write(chunk)
                            downloaded_size += len(chunk)
                            print_progress(downloaded_size, backup_filesize)
                print("\nPobieranie zakończone.")
            except requests.exceptions.RequestException as e:
                 raise Exception(f"Błąd połączenia lub HTTP podczas pobierania pliku: {e}")


        ACTUAL_DOWNLOADED_SIZE = get_file_size(FULL_FINAL_ZIP_PATH)
        if ACTUAL_DOWNLOADED_SIZE is None or ACTUAL_DOWNLOADED_SIZE != backup_filesize:
            raise Exception(f"Rozmiar pobranego pliku ({ACTUAL_DOWNLOADED_SIZE}) nie zgadza się z oczekiwanym ({backup_filesize}).")
        print(f"Backup pobrany pomyślnie do: {FULL_FINAL_ZIP_PATH}")

        print("Rozpakowywanie backupu...")
        original_cwd_unzip = os.getcwd()
        try:
            os.chdir(FULL_TEMP_DIR) # Przejdź do katalogu tymczasowego, aby tam rozpakować
            result_unzip = run_command(["unzip", "-oqq", FINAL_ZIP_FILE]) # -o (overwrite) -qq (quiet)
        finally:
            os.chdir(original_cwd_unzip) # Wróć do poprzedniego katalogu

        if result_unzip is None or result_unzip.returncode != 0:
            raise Exception(f"Błąd rozpakowywania pliku {FINAL_ZIP_FILE}.")
        # Komenda unzip -qq nie zwraca normalnie stdout, chyba że jest błąd.
        # if result_unzip.stdout and result_unzip.stdout.strip():
        #      print(f"Wynik unzip:\n{result_unzip.stdout.strip()}")
        print("Backup rozpakowany.")

        print("Identyfikacja plików backupu...")
        sql_files = [f for f in os.listdir(FULL_TEMP_DIR) if f.endswith('.sql') and f.startswith('database_')]
        if len(sql_files) != 1:
            raise Exception(f"Oczekiwano 1 pliku SQL z backupu (np. database_XXXX.sql), znaleziono {len(sql_files)}: {sql_files} w {FULL_TEMP_DIR}")
        SQL_FILE_PATH = os.path.join(FULL_TEMP_DIR, sql_files[0])
        print(f"Znaleziono plik bazy danych: {SQL_FILE_PATH}")

        # Zmiana katalogu roboczego na WP_ROOT_DIR dla komend WP-CLI
        print(f"Ustawiam katalog roboczy na {WP_ROOT_DIR} dla operacji WP-CLI.")
        os.chdir(WP_ROOT_DIR)


        print("Rozpoczęcie migracji bazy danych...")
        print(f"Pobieranie docelowego URL strony z {WP_ROOT_DIR}...")
        result_siteurl = run_command([WP_CLI_BIN, "option", "get", "siteurl"] + WP_CLI_FLAGS)
        if result_siteurl is None or result_siteurl.returncode != 0 or not result_siteurl.stdout:
            raise Exception(f"Błąd krytyczny: Nie udało się pobrać 'siteurl' z docelowej instalacji WP. stdout: '{result_siteurl.stdout if result_siteurl else ''}', stderr: '{result_siteurl.stderr if result_siteurl else ''}'")
        NEW_URL = result_siteurl.stdout.strip()
        if not NEW_URL:
            raise Exception(f"Błąd krytyczny: Pobrany 'siteurl' jest pusty.")
        print(f"Docelowy URL strony (nowy): {NEW_URL}")

        print(f"Krok 1 DB: Wstępne sprawdzanie/tworzenie bazy danych (jeśli nie istnieje)...")
        # check=False, bo "database exists" to nie błąd tutaj
        result_db_create_initial = run_command([WP_CLI_BIN, "db", "create"] + WP_CLI_FLAGS, check=False)
        if result_db_create_initial is not None:
            if result_db_create_initial.returncode == 0: print("Baza danych utworzona lub potwierdzono istnienie (kod 0).")
            elif result_db_create_initial.stderr and "database exists" in result_db_create_initial.stderr.lower(): print("Baza danych już istniała (komunikat od MySQL).")
            else:
                 # Jeśli nie było "database exists" a kod > 0, to jest problem
                 raise Exception(f"Początkowe 'wp db create' nie powiodło się z nieoczekiwanym błędem (kod: {result_db_create_initial.returncode}). stderr: {result_db_create_initial.stderr}")
        else:
            raise Exception(f"Krytyczny błąd systemowy podczas początkowego 'wp db create'.")


        print("Krok 2 DB: Usuwanie istniejących tabel (drop)...")
        result_db_drop = run_command([WP_CLI_BIN, "db", "drop"] + WP_CLI_FLAGS + ["--yes"])
        if result_db_drop is None or result_db_drop.returncode != 0:
            raise Exception(f"Nie udało się wykonać 'wp db drop' (kod: {result_db_drop.returncode if result_db_drop else 'brak obiektu result'}). stderr: {result_db_drop.stderr if result_db_drop else ''}")
        print("Operacja 'wp db drop' zakończona.")

        print("Krok 3 DB: Ponowne tworzenie bazy danych (jeśli 'drop' ją usunął)...")
        result_db_create_after_drop = run_command([WP_CLI_BIN, "db", "create"] + WP_CLI_FLAGS, check=False)
        if result_db_create_after_drop is not None:
            if result_db_create_after_drop.returncode == 0: print("Baza danych ponownie utworzona lub potwierdzono istnienie.")
            elif result_db_create_after_drop.stderr and "database exists" in result_db_create_after_drop.stderr.lower(): print("Baza danych już istniała (potwierdzone po 'wp db drop').")
            else:
                raise Exception(f"Ponowne 'wp db create' po 'wp db drop' nie powiodło się (kod: {result_db_create_after_drop.returncode}). stderr: {result_db_create_after_drop.stderr}")
        else:
            raise Exception(f"Krytyczny błąd systemowy podczas ponownego 'wp db create'.")


        print(f"Krok 4 DB: Importowanie bazy danych z backupu: {SQL_FILE_PATH}")
        if not os.path.exists(SQL_FILE_PATH): raise Exception(f"Plik SQL '{SQL_FILE_PATH}' nie istnieje! Sprawdź zawartość {FULL_TEMP_DIR}.")
        result_db_import = run_command([WP_CLI_BIN, "db", "import", SQL_FILE_PATH] + WP_CLI_FLAGS)
        if result_db_import is None or result_db_import.returncode != 0:
            raise Exception(f"Nie udało się zaimportować bazy danych ('wp db import {SQL_FILE_PATH}'). stderr: {result_db_import.stderr if result_db_import else ''}")
        print("Baza danych zaimportowana.")

        # --- AKTUALIZACJA PREFIXU TABELI W wp-config.php ---
        print("\nSprawdzanie i aktualizacja prefixu tabel w wp-config.php...")
        backup_wp_config_path = os.path.join(FULL_TEMP_DIR, "wp-config.php") # Ścieżka do wp-config.php z backupu
        target_wp_config_path = WP_CONFIG_DEST_PATH_IN_ROOT     # Ścieżka do wp-config.php w docelowej instalacji

        if not os.path.exists(backup_wp_config_path):
            print(f"Ostrzeżenie: Nie znaleziono pliku wp-config.php w backupie ({backup_wp_config_path}). Nie można automatycznie zaktualizować prefixu tabel. Zakładam, że obecny prefix w {target_wp_config_path} jest poprawny.", file=sys.stderr)
        else:
            backup_table_prefix = get_table_prefix_from_config(backup_wp_config_path)
            if backup_table_prefix:
                print(f"Prefix tabeli odczytany z wp-config.php backupu: '{backup_table_prefix}'")
                current_target_table_prefix = get_table_prefix_from_config(target_wp_config_path)
                print(f"Obecny prefix tabeli w docelowym wp-config.php ({target_wp_config_path}): '{current_target_table_prefix}'")

                if backup_table_prefix != current_target_table_prefix:
                    print(f"Prefixy tabel różnią się. Aktualizuję docelowy {target_wp_config_path}...")
                    if update_table_prefix_in_config(target_wp_config_path, backup_table_prefix):
                        print(f"Prefix tabeli w {target_wp_config_path} zaktualizowany na '{backup_table_prefix}'.")
                    else:
                        raise Exception(f"Nie udało się zaktualizować prefixu tabeli w {target_wp_config_path}. PRZERWANIE SKRYPTU, aby uniknąć problemów z bazą danych.")
                else:
                    print("Prefix tabeli w docelowym wp-config.php jest już zgodny z backupem.")
            else:
                print(f"Ostrzeżenie: Nie udało się odczytać prefixu tabeli z {backup_wp_config_path} (z backupu). Zakładam, że obecny prefix w {target_wp_config_path} jest poprawny.", file=sys.stderr)
        # --- KONIEC AKTUALIZACJI PREFIXU ---

        # --- WP SEARCH-REPLACE ---
        print(f"\nAktualizacja URL-i w bazie danych: zamiana '{SOURCE_DOMAIN}' i jego wariacji na '{NEW_URL}'...")
        search_replace_base_cmd = [WP_CLI_BIN, "search-replace"]
        search_replace_options = ["--all-tables-with-prefix", "--recurse-objects", "--skip-columns=guid", "--precise", "--report-changed-only"] + WP_CLI_FLAGS
        
        # Normalizujemy SOURCE_DOMAIN do postaci bez www na potrzeby porównań, ale zamieniamy z www i bez
        normalized_source_domain = SOURCE_DOMAIN.replace("www.", "")
        
        urls_to_replace = [
            f"http://{normalized_source_domain}", f"https://{normalized_source_domain}",
            f"http://www.{normalized_source_domain}", f"https://www.{normalized_source_domain}"
        ]
        # Usuń duplikaty jeśli SOURCE_DOMAIN już zawierało www.
        urls_to_replace = sorted(list(set(urls_to_replace)))


        for old_url in urls_to_replace:
            print(f"  Zamiana: '{old_url}' -> '{NEW_URL}'")
            run_command(search_replace_base_cmd + [old_url, NEW_URL] + search_replace_options, check=False)

        print("Wyszukiwanie i zamiana URL-i w bazie danych zakończona.")
        # --- KONIEC WP SEARCH-REPLACE ---


        print("Rozpoczęcie migracji plików...")
        print(f"Zachowywanie docelowego wp-config.php (z potencjalnie zaktualizowanym prefixem) do {FULL_TEMP_WP_CONFIG_PATH}...")
        if not os.path.exists(target_wp_config_path): # Używamy target_wp_config_path zamiast WP_CONFIG_DEST_PATH_IN_ROOT dla spójności
            raise Exception(f"Nie znaleziono docelowego wp-config.php w {target_wp_config_path}!")
        shutil.copy2(target_wp_config_path, FULL_TEMP_WP_CONFIG_PATH)
        print("Docelowy wp-config.php zachowany w katalogu tymczasowym.")

        target_wp_content_full_path = os.path.join(WP_ROOT_DIR, WP_CONTENT_DIR_NAME)
        print(f"Usuwanie istniejącego katalogu {target_wp_content_full_path} (jeśli istnieje)...")
        if os.path.isdir(target_wp_content_full_path):
            shutil.rmtree(target_wp_content_full_path)
            print(f"Katalog {target_wp_content_full_path} usunięty.")
        elif os.path.exists(target_wp_content_full_path): # Jeśli to plik, a nie katalog
             os.remove(target_wp_content_full_path)
             print(f"Plik {target_wp_content_full_path} (oczekiwano katalogu) usunięty.")
        else:
            print(f"Katalog {target_wp_content_full_path} nie istniał.")

        print(f"Przenoszenie zawartości z backupu ({FULL_TEMP_DIR}) do {WP_ROOT_DIR}...")
        # Elementy do wykluczenia z przenoszenia z katalogu tymczasowego do WP_ROOT_DIR
        items_to_exclude_from_move = [
            os.path.basename(SQL_FILE_PATH),        # np. database_xxxx.sql
            FINAL_ZIP_FILE,                         # np. backup_finalny.zip
            os.path.basename(FULL_TEMP_WP_CONFIG_PATH), # np. wp-config.php.original_target
            "wp-config.php" # Plik wp-config.php z backupu (nie chcemy go nadpisywać nad naszym zachowanym)
        ]
        moved_items_count = 0
        for item_name in os.listdir(FULL_TEMP_DIR):
            if item_name not in items_to_exclude_from_move:
                source_item_path = os.path.join(FULL_TEMP_DIR, item_name)
                destination_item_path = os.path.join(WP_ROOT_DIR, item_name)

                # Jeśli element docelowy istnieje, usuń go przed przeniesieniem, aby uniknąć błędów (np. przy przenoszeniu katalogu na plik)
                if os.path.exists(destination_item_path):
                    print(f"Ostrzeżenie: Element docelowy {destination_item_path} istnieje. Zostanie usunięty i nadpisany przez element z backupu.")
                    if os.path.isdir(destination_item_path):
                        shutil.rmtree(destination_item_path)
                    else:
                        os.remove(destination_item_path)
                
                # Użyj shutil.move, aby przenieść
                shutil.move(source_item_path, destination_item_path)
                moved_items_count +=1
                print(f"Przeniesiono: {item_name} z {source_item_path} do {destination_item_path}")

        if moved_items_count == 0 :
             print("Ostrzeżenie: Nie przeniesiono żadnych głównych elementów z katalogu backupu (np. wp-content). Sprawdź strukturę backupu w {FULL_TEMP_DIR}.")
        print("Pliki/katalogi z backupu przeniesione.")

        print(f"Przywracanie oryginalnego (ale zaktualizowanego o prefix) wp-config.php z {FULL_TEMP_WP_CONFIG_PATH} do {target_wp_config_path}...")
        shutil.copy2(FULL_TEMP_WP_CONFIG_PATH, target_wp_config_path) # Kopiujemy zachowany plik z powrotem
        print(f"Plik wp-config.php przywrócony do {target_wp_config_path}.")


        print(f"Ustawianie uprawnień plików w {WP_ROOT_DIR}...")
        # Upewnij się, że jesteśmy w WP_ROOT_DIR dla komend find
        os.chdir(WP_ROOT_DIR)
        run_command(["chown", "-R", f"{WEB_USER}:{WEB_GROUP}", "."], check=False) # check=False na wypadek problemów z niektórymi plikami
        run_command(["find", ".", "-type", "d", "-exec", "chmod", "755", "{}", "+"], check=False)
        run_command(["find", ".", "-type", "f", "-exec", "chmod", "644", "{}", "+"], check=False)
        if os.path.exists("wp-config.php"):
            run_command(["chmod", "640", "wp-config.php"], check=False) # Bardziej restrykcyjne dla wp-config
        print("Uprawnienia plików ustawione (mogły wystąpić ostrzeżenia, jeśli niektóre pliki miały specjalne uprawnienia).")

        print("Wykonywanie końcowych operacji WP-CLI...")
        # Upewnij się, że jesteśmy w WP_ROOT_DIR
        os.chdir(WP_ROOT_DIR)
        print("Odświeżanie permanentnych linków...")
        run_command([WP_CLI_BIN, "rewrite", "flush", "--hard"] + WP_CLI_FLAGS, check=False) # check=False, bo to czasem zawodzi na świeżych instalacjach

        print(f"Aktualizacja opcji 'siteurl' i 'home' do {NEW_URL} (dodatkowe upewnienie)...")
        run_command([WP_CLI_BIN, "option", "update", "siteurl", NEW_URL] + WP_CLI_FLAGS, check=False)
        run_command([WP_CLI_BIN, "option", "update", "home", NEW_URL] + WP_CLI_FLAGS, check=False)
        print("'siteurl' i 'home' zaktualizowane.")

        print("Pominięto automatyczną aktualizację rdzenia, wtyczek i motywów.")
        # print("Aktualizacja rdzenia WordPressa...")
        # run_command([WP_CLI_BIN, "core", "update"] + WP_CLI_FLAGS, check=False)
        # print("Aktualizacja wtyczek...")
        # run_command([WP_CLI_BIN, "plugin", "update", "--all"] + WP_CLI_FLAGS, check=False)
        # print("Aktualizacja motywów...")
        # run_command([WP_CLI_BIN, "theme", "update", "--all"] + WP_CLI_FLAGS, check=False)


        print("Czyszczenie cache WP (jeśli wspierane)...")
        run_command([WP_CLI_BIN, "cache", "flush"] + WP_CLI_FLAGS, check=False) # check=False, bo nie każdy WP ma aktywny cache
        print("Operacje WP-CLI zakończone.")

    except Exception as e:
        print(f"KRYTYCZNY BŁĄD SKRYPTU: {e}", file=sys.stderr)
        import traceback
        traceback.print_exc(file=sys.stderr) # Dodatkowy traceback dla debugowania
        exit_code = 1
    finally:
        if exit_code != 0:
            print(f"\nWAŻNE: Katalog tymczasowy {FULL_TEMP_DIR} NIE został usunięty z powodu błędu. Sprawdź jego zawartość.", file=sys.stderr)
            print(f"Możesz go usunąć ręcznie: rm -rf {FULL_TEMP_DIR}", file=sys.stderr)
        else:
            print("\nSprzątanie plików tymczasowych...")
            cleanup_temp_dir()

        if exit_code == 0 and NEW_URL:
            print("\n---------------------------------------------------")
            print("Migracja zakończona pomyślnie!")
            print(f"Docelowa strona powinna teraz działać pod adresem: {NEW_URL}")
            print(f"Skrypt WYKONAŁ automatyczne wyszukiwanie i zamianę URL-i")
            print(f"(z '{SOURCE_DOMAIN}' i jego wariacji na '{NEW_URL}') we wszystkich tabelach z prefixem.")
            print("Operacja wp search-replace została przeprowadzona z opcjami: --all-tables-with-prefix --recurse-objects --skip-columns=guid --precise --report-changed-only")
            print("Zawsze ZALECANE jest ręczne sprawdzenie strony po migracji oraz logów serwera!")
            print("---------------------------------------------------")
        elif exit_code == 0:
            print("\n---------------------------------------------------")
            print("Migracja zakończona (ale NEW_URL nie został ustalony - sprawdź logi).")
            print("Sprawdź logi powyżej pod kątem ewentualnych ostrzeżeń lub błędów.")
            print("---------------------------------------------------")


        sys.exit(exit_code)

if __name__ == "__main__":
    # Upewnij się, że WP_CLI_BIN jest globalne i może być modyfikowane
    # Definicja WP_CLI_BIN jest już na poziomie globalnym, main() ją modyfikuje
    main()