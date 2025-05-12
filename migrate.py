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
WP_CLI_BIN = "wp"
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
            print(f"Ostrzeżenie: Komenda '{' '.join(command)}' zwróciła kod wyjścia {result.returncode}", file=sys.stderr)
            if result.stdout and result.stdout.strip(): print(f"Stdout (Ostrzeżenie):\n{result.stdout.strip()}", file=sys.stderr)
            if result.stderr and result.stderr.strip(): print(f"Stderr (Ostrzeżenie):\n{result.stderr.strip()}", file=sys.stderr)
        return result
    except subprocess.CalledProcessError as e:
        print(f"Błąd: Komenda '{' '.join(command)}' zwróciła kod wyjścia {e.returncode}", file=sys.stderr)
        if e.stdout and e.stdout.strip(): print(f"Stdout (Błąd):\n{e.stdout.strip()}", file=sys.stderr)
        if e.stderr and e.stderr.strip(): print(f"Stderr (Błąd):\n{e.stderr.strip()}", file=sys.stderr)
        return None
    except FileNotFoundError:
        print(f"Błąd: Komenda '{command[0]}' nie znaleziona.", file=sys.stderr)
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
    NEW_URL = "" # Zmienna przechowująca docelowy URL

    try:
        print(f"Przechodzenie do katalogu WordPressa docelowego: {WP_ROOT_DIR}")
        os.chdir(WP_ROOT_DIR)
        print(f"Jesteś w katalogu: {os.getcwd()}")

        print("Sprawdzanie wymaganych narzędzi...")
        if not shutil.which("unzip"): raise Exception("Wymagany 'unzip' nie jest zainstalowany.")
        if not shutil.which(WP_CLI_BIN): raise Exception(f"WP-CLI ('{WP_CLI_BIN}') nie jest zainstalowane.")

        wp_version_result = run_command([WP_CLI_BIN, "--version"] + WP_CLI_FLAGS)
        if wp_version_result is None or wp_version_result.returncode != 0:
            raise Exception(f"Nie można uruchomić WP-CLI. Sprawdź uprawnienia/konfigurację.")
        if wp_version_result.stdout: print(wp_version_result.stdout.strip())
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
        trigger_response = requests.post(TRIGGER_ENDPOINT, headers=headers, timeout=60)
        trigger_response.raise_for_status()
        trigger_data = trigger_response.json()
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
            print("\nPusty plik utworzony.")
        else:
            with requests.get(DOWNLOAD_ENDPOINT, headers=headers, stream=True, timeout=300) as r:
                r.raise_for_status()
                with open(FULL_FINAL_ZIP_PATH, 'wb') as f:
                    for chunk in r.iter_content(chunk_size=CHUNK_SIZE):
                        f.write(chunk)
                        downloaded_size += len(chunk)
                        print_progress(downloaded_size, backup_filesize)
            print("\nPobieranie zakończone.")

        ACTUAL_DOWNLOADED_SIZE = get_file_size(FULL_FINAL_ZIP_PATH)
        if ACTUAL_DOWNLOADED_SIZE is None or ACTUAL_DOWNLOADED_SIZE != backup_filesize:
            raise Exception(f"Rozmiar pliku ({ACTUAL_DOWNLOADED_SIZE}) != oczekiwany ({backup_filesize}).")
        print(f"Backup pobrany pomyślnie do: {FULL_FINAL_ZIP_PATH}")

        print("Rozpakowywanie backupu...")
        original_cwd_unzip = os.getcwd()
        try:
            os.chdir(FULL_TEMP_DIR)
            result_unzip = run_command(["unzip", "-o", FINAL_ZIP_FILE])
        finally:
            os.chdir(original_cwd_unzip)

        if result_unzip is None or result_unzip.returncode != 0:
            raise Exception(f"Błąd rozpakowywania.")
        if result_unzip.stdout and result_unzip.stdout.strip():
             print(f"Wynik unzip:\n{result_unzip.stdout.strip()}")
        print("Backup rozpakowany.")

        print("Identyfikacja plików backupu...")
        sql_files = [f for f in os.listdir(FULL_TEMP_DIR) if f.endswith('.sql') and f.startswith('database_')]
        if len(sql_files) != 1:
            raise Exception(f"Oczekiwano 1 pliku SQL, znaleziono {len(sql_files)}: {sql_files}")
        SQL_FILE_PATH = os.path.join(FULL_TEMP_DIR, sql_files[0])
        print(f"Znaleziono plik bazy danych: {SQL_FILE_PATH}")

        print("Rozpoczęcie migracji bazy danych...")
        print(f"Pobieranie docelowego URL strony z {WP_ROOT_DIR}...")
        result_siteurl = run_command([WP_CLI_BIN, "option", "get", "siteurl"] + WP_CLI_FLAGS)
        if result_siteurl is None or result_siteurl.returncode != 0 or not result_siteurl.stdout:
            raise Exception(f"Błąd krytyczny: Nie udało się pobrać 'siteurl'.")
        NEW_URL = result_siteurl.stdout.strip()
        if not NEW_URL:
            raise Exception(f"Błąd krytyczny: Pobrany 'siteurl' jest pusty.")
        print(f"Docelowy URL strony (nowy): {NEW_URL}")

        print(f"Krok 1 DB: Wstępne sprawdzanie/tworzenie bazy danych...")
        result_db_create_initial = run_command([WP_CLI_BIN, "db", "create"] + WP_CLI_FLAGS, check=False)
        if result_db_create_initial is not None:
            if result_db_create_initial.returncode == 0: print("Baza danych utworzona lub potwierdzono istnienie (kod 0).")
            elif result_db_create_initial.stderr and "database exists" in result_db_create_initial.stderr.lower(): print("Baza danych już istniała (komunikat od MySQL).")
            else: raise Exception(f"Początkowe 'wp db create' nie powiodło się (kod: {result_db_create_initial.returncode}).")
        else: raise Exception(f"Krytyczny błąd systemowy podczas początkowego 'wp db create'.")


        print("Krok 2 DB: Usuwanie bazy danych/tabel...")
        result_db_drop = run_command([WP_CLI_BIN, "db", "drop"] + WP_CLI_FLAGS + ["--yes"])
        if result_db_drop is None or result_db_drop.returncode != 0:
            raise Exception(f"Nie udało się wykonać 'wp db drop' (kod: {result_db_drop.returncode if result_db_drop else 'brak'}).")
        print("Operacja 'wp db drop' zakończona.")

        print("Krok 3 DB: Ponowne tworzenie bazy danych (jeśli została usunięta)...")
        result_db_create_after_drop = run_command([WP_CLI_BIN, "db", "create"] + WP_CLI_FLAGS, check=False)
        if result_db_create_after_drop is None or result_db_create_after_drop.returncode != 0:
            if not (result_db_create_after_drop.stderr and "database exists" in result_db_create_after_drop.stderr.lower()):
                 raise Exception(f"Ponowne 'wp db create' po 'wp db drop' nie powiodło się (kod: {result_db_create_after_drop.returncode if result_db_create_after_drop else 'brak'}).")
            else: print("Baza danych już istniała (potwierdzone po 'wp db drop').")
        else: print("Baza danych ponownie utworzona (lub potwierdzono istnienie).")


        print("Krok 4 DB: Sprawdzanie dostępności bazy danych PRZED importem...")
        check_db_result = run_command([WP_CLI_BIN, "db", "check"] + WP_CLI_FLAGS, check=False)
        if not (check_db_result and check_db_result.returncode == 0):
            print("Ostrzeżenie/Błąd: 'wp db check' nie powiodło się PRZED importem. Być może plik SQL zawiera CREATE DATABASE.", file=sys.stderr)
        else: print("Wynik 'wp db check' przed importem: OK.")


        print(f"Krok 5 DB: Importowanie bazy danych z backupu: {SQL_FILE_PATH}")
        if not os.path.exists(SQL_FILE_PATH): raise Exception(f"Plik SQL '{SQL_FILE_PATH}' nie istnieje!")
        result_db_import = run_command([WP_CLI_BIN, "db", "import", SQL_FILE_PATH] + WP_CLI_FLAGS)
        if result_db_import is None or result_db_import.returncode != 0:
            raise Exception(f"Nie udało się zaimportować bazy danych (wp db import).")
        print("Baza danych zaimportowana.")

        # --- AKTUALIZACJA PREFIXU TABELI W wp-config.php ---
        print("Sprawdzanie i aktualizacja prefixu tabel w wp-config.php...")
        backup_wp_config_path = os.path.join(FULL_TEMP_DIR, "wp-config.php")
        if not os.path.exists(backup_wp_config_path):
            print(f"Ostrzeżenie: Nie znaleziono pliku wp-config.php w backupie ({backup_wp_config_path}). Nie można automatycznie zaktualizować prefixu tabel. Zakładam, że jest poprawny.", file=sys.stderr)
        else:
            backup_table_prefix = get_table_prefix_from_config(backup_wp_config_path)
            if backup_table_prefix:
                print(f"Prefix tabeli odczytany z backupu: '{backup_table_prefix}'")
                current_target_table_prefix = get_table_prefix_from_config(WP_CONFIG_DEST_PATH_IN_ROOT)
                print(f"Obecny prefix tabeli w docelowym wp-config.php: '{current_target_table_prefix}'")

                if backup_table_prefix != current_target_table_prefix:
                    print(f"Prefixy tabel różnią się. Aktualizuję docelowy {WP_CONFIG_DEST_PATH_IN_ROOT}...")
                    if update_table_prefix_in_config(WP_CONFIG_DEST_PATH_IN_ROOT, backup_table_prefix):
                        print(f"Prefix tabeli w {WP_CONFIG_DEST_PATH_IN_ROOT} zaktualizowany na '{backup_table_prefix}'.")
                    else:
                        raise Exception(f"Nie udało się zaktualizować prefixu tabeli w {WP_CONFIG_DEST_PATH_IN_ROOT}.")
                else:
                    print("Prefix tabeli w docelowym wp-config.php jest już zgodny z backupem.")
            else:
                print(f"Ostrzeżenie: Nie udało się odczytać prefixu tabeli z {backup_wp_config_path}. Zakładam, że obecny jest poprawny.", file=sys.stderr)
        # --- KONIEC AKTUALIZACJI PREFIXU ---

        # --- USUNIĘTO SEKCJĘ WP SEARCH-REPLACE ---
        # print(f"Aktualizacja URL-i w bazie danych: zamiana '{SOURCE_DOMAIN}' na '{NEW_URL}'...")
        # search_replace_base_cmd = [WP_CLI_BIN, "search-replace"]
        # search_replace_options = ["--all-tables-with-prefix", "--recurse-objects", "--skip-columns=guid", "--precise", "--report-changed-only"] + WP_CLI_FLAGS
        # urls_to_replace = [ f"http://{SOURCE_DOMAIN}", f"https://{SOURCE_DOMAIN}", f"http://www.{SOURCE_DOMAIN}", f"https://www.{SOURCE_DOMAIN}" ]
        # for old_url in urls_to_replace:
        #     sr_result = run_command(search_replace_base_cmd + [old_url, NEW_URL] + search_replace_options, check=False)
        #     if sr_result and sr_result.returncode != 0:
        #          print(f"Ostrzeżenie podczas search-replace dla {old_url}. Może to być normalne, jeśli URL nie występował.", file=sys.stderr)
        # print("Aktualizacja URL-i zakończona.")
        print("Pominięto automatyczne wyszukiwanie i zamianę URL-i w bazie danych.")
        print(f"Skrypt zaktualizuje tylko opcje siteurl i home do '{NEW_URL}'.")
        print("Będziesz musiał zaktualizować pozostałe wystąpienia starego URL-a ręcznie.")
        # --- KONIEC USUNIĘTEJ SEKCJI ---

        print("Rozpoczęcie migracji plików...")
        print(f"Zachowywanie docelowego wp-config.php do {FULL_TEMP_WP_CONFIG_PATH}...")
        if not os.path.exists(WP_CONFIG_DEST_PATH_IN_ROOT):
            raise Exception(f"Nie znaleziono docelowego wp-config.php w {WP_ROOT_DIR}!")
        shutil.copy2(WP_CONFIG_DEST_PATH_IN_ROOT, FULL_TEMP_WP_CONFIG_PATH)
        print("Docelowy wp-config.php zachowany.")

        target_wp_content_full_path = os.path.join(WP_ROOT_DIR, WP_CONTENT_DIR_NAME)
        print(f"Usuwanie istniejącego katalogu {target_wp_content_full_path} (jeśli istnieje)...")
        if os.path.isdir(target_wp_content_full_path):
            shutil.rmtree(target_wp_content_full_path)
            print(f"Katalog {target_wp_content_full_path} usunięty.")
        elif os.path.exists(target_wp_content_full_path):
             os.remove(target_wp_content_full_path)
             print(f"Plik {target_wp_content_full_path} (oczekiwano katalogu) usunięty.")
        else:
            print(f"Katalog {target_wp_content_full_path} nie istniał.")

        print(f"Przenoszenie zawartości z backupu ({FULL_TEMP_DIR}) do {WP_ROOT_DIR}...")
        items_to_exclude_from_move = [
            os.path.basename(SQL_FILE_PATH),
            FINAL_ZIP_FILE,
            os.path.basename(FULL_TEMP_WP_CONFIG_PATH),
            "wp-config.php" # Wykluczamy również wp-config.php z backupu, używamy docelowego
        ]
        moved_items_count = 0
        for item_name in os.listdir(FULL_TEMP_DIR):
            if item_name not in items_to_exclude_from_move:
                source_item_path = os.path.join(FULL_TEMP_DIR, item_name)
                destination_item_path = os.path.join(WP_ROOT_DIR, item_name)

                if os.path.exists(destination_item_path):
                    print(f"Ostrzeżenie: Element docelowy {destination_item_path} istnieje. Zostanie nadpisany przez element z backupu.")
                    if os.path.isdir(destination_item_path): shutil.rmtree(destination_item_path)
                    else: os.remove(destination_item_path)

                shutil.move(source_item_path, destination_item_path)
                moved_items_count +=1
                print(f"Przeniesiono: {item_name} do {destination_item_path}")

        if moved_items_count == 0 :
             print("Ostrzeżenie: Nie przeniesiono żadnych głównych elementów z backupu (np. wp-content). Sprawdź strukturę backupu.")
        print("Pliki/katalogi z backupu przeniesione.")

        print(f"Przywracanie oryginalnego (ale potencjalnie zaktualizowanego o prefix) wp-config.php z {FULL_TEMP_WP_CONFIG_PATH}...")
        # Plik w docelowym WP_ROOT_DIR jest już właściwy po kroku aktualizacji prefixu
        # Nie ma potrzeby kopiować go z powrotem, bo tam cały czas był (nie został usunięty/nadpisany)
        print(f"Plik {WP_CONFIG_DEST_PATH_IN_ROOT} powinien już być poprawny (zaktualizowany prefix, jeśli było trzeba).")


        print(f"Ustawianie uprawnień plików w {WP_ROOT_DIR}...")
        os.chdir(WP_ROOT_DIR)
        run_command(["chown", "-R", f"{WEB_USER}:{WEB_GROUP}", "."], check=False)
        run_command(["find", ".", "-type", "d", "-exec", "chmod", "755", "{}", "+"], check=False)
        run_command(["find", ".", "-type", "f", "-exec", "chmod", "644", "{}", "+"], check=False)
        if os.path.exists("wp-config.php"): run_command(["chmod", "640", "wp-config.php"], check=False)
        print("Uprawnienia plików ustawione.")

        print("Wykonywanie końcowych operacji WP-CLI...")
        os.chdir(WP_ROOT_DIR)
        print("Odświeżanie permanentnych linków...")
        run_command([WP_CLI_BIN, "rewrite", "flush", "--hard"] + WP_CLI_FLAGS, check=False)

        print(f"Aktualizacja opcji 'siteurl' i 'home' do {NEW_URL}...")
        run_command([WP_CLI_BIN, "option", "update", "siteurl", NEW_URL] + WP_CLI_FLAGS, check=False)
        run_command([WP_CLI_BIN, "option", "update", "home", NEW_URL] + WP_CLI_FLAGS, check=False)
        print("'siteurl' i 'home' zaktualizowane.")

        # Usunięto automatyczne aktualizacje (były już skomentowane)
        # print("Aktualizacja rdzenia, wtyczek i motywów (opcjonalnie)...")
        # run_command([WP_CLI_BIN, "core", "update"] + WP_CLI_FLAGS, check=False)
        # run_command([WP_CLI_BIN, "plugin", "update", "--all"] + WP_CLI_FLAGS, check=False)
        # run_command([WP_CLI_BIN, "theme", "update", "--all"] + WP_CLI_FLAGS, check=False)
        print("Pominięto aktualizację rdzenia, wtyczek i motywów.")

        print("Czyszczenie cache WP...")
        run_command([WP_CLI_BIN, "cache", "flush"] + WP_CLI_FLAGS, check=False)
        print("Operacje WP-CLI zakończone.")

    except Exception as e:
        print(f"KRYTYCZNY BŁĄD SKRYPTU: {e}", file=sys.stderr)
        exit_code = 1
    finally:
        if exit_code != 0:
            print(f"WAŻNE: Katalog tymczasowy {FULL_TEMP_DIR} NIE został usunięty z powodu błędu. Sprawdź jego zawartość.", file=sys.stderr)
            print(f"Możesz go usunąć ręcznie: rm -rf {FULL_TEMP_DIR}", file=sys.stderr)
        else:
            print("Sprzątanie plików tymczasowych...")
            cleanup_temp_dir()

        if exit_code == 0 and NEW_URL:
            print("\n---------------------------------------------------")
            print("Migracja zakończona!")
            print(f"Docelowa strona powinna teraz działać pod adresem: {NEW_URL}")
            print("Pamiętaj, że skrypt NIE zaktualizował wszystkich URL-i w bazie danych (np. w treściach artykułów).")
            print("Musisz wykonać globalne search-replace ręcznie, np. używając:")
            print(f"wp search-replace 'https://{SOURCE_DOMAIN}' '{NEW_URL}' --all-tables-with-prefix --skip-columns=guid --recurse-objects")
            print("Pamiętaj o dostosowaniu starego URL-a (http/https/www).")
            print("Pamiętaj również o ręcznym sprawdzeniu strony i logów serwera!")
            print("---------------------------------------------------")
        elif exit_code == 0:
            print("\n---------------------------------------------------")
            print("Migracja zakończona (lub anulowana/błąd przed pobraniem URL).")
            print("---------------------------------------------------")

        sys.exit(exit_code)

if __name__ == "__main__":
    main()