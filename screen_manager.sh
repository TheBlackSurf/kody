#!/bin/bash

# ═══════════════════════════════════════════════════════════════════════════════
# 🚀 ZAAWANSOWANY MENEDŻER SESJI SCREEN
# ═══════════════════════════════════════════════════════════════════════════════
# Wersja 2.1 - Interaktywny interfejs z paskiem ładowania i kolorami
# Teraz możesz uruchamiać DOWOLNĄ komendę w nowej sesji Screen!
# Autor: AI Assistant
# Data: 2025
# ═══════════════════════════════════════════════════════════════════════════════

# Globalna nazwa sesji domyślnej (używana jako sugestia, nie wymuszona)
DEFAULT_SESSION_NAME="my_screen_session"
SCRIPT_VERSION="2.1"

# Kolory dla lepszej czytelności
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Funkcja wyświetlająca pasek ładowania
show_loading_bar() {
    local duration=$1
    local message=$2
    local width=50
    
    echo -e "${CYAN}${message}${NC}"
    echo -n "["
    
    for ((i=0; i<=width; i++)); do
        local percent=$((i * 100 / width))
        printf "\r[%-${width}s] %d%%" $(printf "█%.0s" $(seq 1 $i)) $percent
        sleep $(echo "scale=3; $duration / $width" | bc -l 2>/dev/null || echo "0.02")
    done
    echo
    echo -e "${GREEN}✓ Gotowe!${NC}"
    echo
}

# Funkcja wyświetlająca nagłówek
show_header() {
    clear
    echo -e "${PURPLE}═══════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${WHITE}${BOLD}🚀 ZAAWANSOWANY MENEDŻER SESJI SCREEN v${SCRIPT_VERSION}${NC}"
    echo -e "${PURPLE}═══════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}📅 Data: $(date '+%Y-%m-%d %H:%M:%S')${NC}"
    echo -e "${CYAN}👤 Użytkownik: $(whoami)${NC}"
    echo -e "${CYAN}💻 System: $(uname -s)${NC}"
    echo -e "${PURPLE}═══════════════════════════════════════════════════════════════════════════════${NC}"
    echo
}

# Funkcja wyświetlająca menu główne
show_main_menu() {
    echo -e "${WHITE}${BOLD}📋 MENU GŁÓWNE${NC}"
    echo -e "${PURPLE}─────────────────────────────────────────────────────────────────────────────${NC}"
    echo -e "${GREEN}[1]${NC} 🚀 Uruchom nową sesję Screen z komendą"
    echo -e "${BLUE}[2]${NC} 📋 Wyświetl aktywne sesje"
    echo -e "${YELLOW}[3]${NC} 🔄 Wznów istniejącą sesję"
    echo -e "${RED}[4]${NC} ❌ Zamknij sesję"
    echo -e "${CYAN}[5]${NC} 📊 Status systemu"
    echo -e "${PURPLE}[6]${NC} ℹ️  Pomoc i instrukcje"
    echo -e "${WHITE}[0]${NC} 🚪 Wyjście"
    echo -e "${PURPLE}─────────────────────────────────────────────────────────────────────────────${NC}"
    echo
}

# Funkcja wyświetlająca informacje o systemie
show_system_status() {
    echo -e "${WHITE}${BOLD}📊 STATUS SYSTEMU${NC}"
    echo -e "${PURPLE}─────────────────────────────────────────────────────────────────────────────${NC}"
    
    # Sprawdzenie czy screen jest zainstalowany
    if command -v screen &> /dev/null; then
        echo -e "${GREEN}✓ Screen jest zainstalowany${NC} ($(screen --version | head -1))"
    else
        echo -e "${RED}✗ Screen nie jest zainstalowany!${NC}"
        echo -e "${YELLOW}  Zainstaluj używając: sudo apt install screen (Ubuntu/Debian) lub sudo yum install screen (RHEL/CentOS)${NC}"
    fi
    
    # Liczba aktywnych sesji screen
    local session_count=$(screen -ls 2>/dev/null | grep -c "Socket" || echo "0")
    echo -e "${CYAN}📊 Aktywne sesje Screen: ${session_count}${NC}"
    
    # Wykorzystanie pamięci
    if command -v free &> /dev/null; then
        local mem_usage=$(free | grep '^Mem:' | awk '{printf "%.1f%%", $3/$2 * 100}')
        echo -e "${CYAN}💾 Wykorzystanie pamięci: ${mem_usage}${NC}"
    fi
    
    # Uptime systemu
    if command -v uptime &> /dev/null; then
        echo -e "${CYAN}⏰ Uptime systemu: $(uptime -p 2>/dev/null || uptime)${NC}"
    fi
    
    echo -e "${PURPLE}─────────────────────────────────────────────────────────────────────────────${NC}"
    echo
}

# Funkcja uruchamiająca nową sesję
start_new_session() {
    local new_session_name="$1"
    local command_to_run="$2"

    echo -e "${WHITE}${BOLD}🚀 URUCHAMIANIE NOWEJ SESJI SCREEN${NC}"
    echo -e "${PURPLE}─────────────────────────────────────────────────────────────────────────────${NC}"
    
    if [ -z "$new_session_name" ]; then
        read -p "$(echo -e ${CYAN}Podaj nazwę dla nowej sesji [Enter = $DEFAULT_SESSION_NAME]:${NC} )" new_session_name
        if [ -z "$new_session_name" ]; then
            new_session_name="$DEFAULT_SESSION_NAME"
        fi
    fi

    if [ -z "$command_to_run" ]; then
        read -p "$(echo -e ${CYAN}Podaj komendę do uruchomienia w sesji (np. honcho start, python app.py):${NC} )" command_to_run
        if [ -z "$command_to_run" ]; then
            echo -e "${RED}❌ Komenda nie może być pusta. Anuluję.${NC}"
            read -p "$(echo -e ${WHITE}Naciśnij Enter, aby kontynuować...${NC})"
            return 1
        fi
    fi

    # Sprawdzenie czy sesja już istnieje
    if screen -ls 2>/dev/null | grep -q "$new_session_name"; then
        echo -e "${YELLOW}⚠️  Sesja '$new_session_name' już istnieje!${NC}"
        echo
        echo -e "${WHITE}Co chcesz zrobić?${NC}"
        echo -e "${GREEN}[1]${NC} Dołącz do istniejącej sesji"
        echo -e "${RED}[2]${NC} Usuń starą sesję i utwórz nową"
        echo -e "${BLUE}[3]${NC} Powrót do menu głównego"
        echo
        read -p "$(echo -e ${CYAN}Twój wybór [1-3]:${NC} )" choice
        
        case $choice in
            1)
                resume_screen_session "$new_session_name"
                return
                ;;
            2)
                echo -e "${YELLOW}Usuwam starą sesję...${NC}"
                screen -X -S "$new_session_name" quit 2>/dev/null
                show_loading_bar 1 "Czyszczenie starej sesji..."
                ;;
            3)
                return
                ;;
            *)
                echo -e "${RED}Nieprawidłowy wybór. Powrót do menu.${NC}"
                return
                ;;
        esac
    fi
    
    # Sprawdzenie dostępności screen
    if ! command -v screen &> /dev/null; then
        echo -e "${RED}❌ Błąd: Screen nie jest zainstalowany!${NC}"
        echo -e "${YELLOW}Zainstaluj go, aby używać tego skryptu.${NC}"
        read -p "$(echo -e ${WHITE}Naciśnij Enter, aby kontynuować...${NC})"
        return 1
    fi
    
    show_loading_bar 2 "Przygotowywanie nowej sesji Screen '$new_session_name'..."
    
    # Tworzenie nowej sesji
    screen -dmS "$new_session_name" bash -c "
        echo 'Sesja Screen: $new_session_name została uruchomiona';
        echo 'Uruchamianie komendy: $command_to_run...';
        echo '════════════════════════════════════════';
        $command_to_run;
        echo '════════════════════════════════════════';
        echo 'Komenda zakończona. Sesja pozostaje aktywna.';
        echo 'Aby zamknąć sesję, wpisz: exit';
        exec bash
    "
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✅ Sesja '$new_session_name' została pomyślnie utworzona!${NC}"
        echo
        echo -e "${CYAN}📋 Przydatne informacje:${NC}"
        echo -e "${WHITE}• Nazwa sesji: ${new_session_name}${NC}"
        echo -e "${WHITE}• Komenda uruchomiona: ${command_to_run}${NC}"
        echo -e "${WHITE}• Aby dołączyć do sesji: wybierz opcję 3 w menu${NC}"
        echo -e "${WHITE}• Aby odłączyć się od sesji: Ctrl+A, następnie D${NC}"
        echo -e "${WHITE}• Aby zakończyć komendę: Ctrl+C (w sesji)${NC}"
        echo -e "${WHITE}• Aby zamknąć sesję: wpisz 'exit' (w sesji)${NC}"
    else
        echo -e "${RED}❌ Błąd podczas tworzenia sesji!${NC}"
    fi
    
    echo
    read -p "$(echo -e ${WHITE}Naciśnij Enter, aby kontynuować...${NC})"
}

# Funkcja listująca sesje
list_screen_sessions() {
    echo -e "${WHITE}${BOLD}📋 AKTYWNE SESJE SCREEN${NC}"
    echo -e "${PURPLE}─────────────────────────────────────────────────────────────────────────────${NC}"
    
    show_loading_bar 0.5 "Pobieranie listy sesji..."
    
    local sessions_output=$(screen -ls 2>&1)
    
    if echo "$sessions_output" | grep -q "No Sockets found"; then
        echo -e "${YELLOW}📭 Brak aktywnych sesji Screen.${NC}"
    else
        echo -e "${CYAN}Znalezione sesje:${NC}"
        echo
        
        # Formatowanie wyjścia screen -ls
        echo "$sessions_output" | grep -E "^\s*[0-9]+\." | while read line; do
            if echo "$line" | grep -q "(Detached)"; then
                echo -e "${GREEN}🟢 $line${NC}"
            elif echo "$line" | grep -q "(Attached)"; then
                echo -e "${BLUE}🔵 $line${NC}"
            else
                echo -e "${WHITE}⚪ $line${NC}"
            fi
        done
        
        echo
        echo -e "${CYAN}Legenda:${NC}"
        echo -e "${GREEN}🟢 Detached${NC} - Sesja działa w tle, można się do niej dołączyć"
        echo -e "${BLUE}🔵 Attached${NC} - Sesja jest aktywnie używana"
        echo -e "${WHITE}⚪ Inne${NC} - Inne stany sesji"
    fi
    
    echo -e "${PURPLE}─────────────────────────────────────────────────────────────────────────────${NC}"
    echo
    read -p "$(echo -e ${WHITE}Naciśnij Enter, aby kontynuować...${NC})"
}

# Funkcja wznawiająca sesję
resume_screen_session() {
    local predefined_session="$1"
    
    echo -e "${WHITE}${BOLD}🔄 WZNAWIANIE SESJI SCREEN${NC}"
    echo -e "${PURPLE}─────────────────────────────────────────────────────────────────────────────${NC}"
    
    # Wyświetlenie dostępnych sesji
    local sessions_output=$(screen -ls 2>&1)
    
    if echo "$sessions_output" | grep -q "No Sockets found"; then
        echo -e "${RED}❌ Brak aktywnych sesji Screen do wznowienia.${NC}"
        echo -e "${YELLOW}Utwórz nową sesję wybierając opcję 1 w menu głównym.${NC}"
        echo
        read -p "$(echo -e ${WHITE}Naciśnij Enter, aby kontynuować...${NC})"
        return
    fi
    
    echo -e "${CYAN}Dostępne sesje:${NC}"
    echo
    echo "$sessions_output" | grep -E "^\s*[0-9]+\." | nl -w2 -s') '
    echo
    
    local session_id=""
    if [ -n "$predefined_session" ]; then
        session_id="$predefined_session"
        echo -e "${CYAN}Wybrano predefiniowaną sesję: $session_id${NC}"
    else
        echo -e "${WHITE}Wybierz sesję do wznowienia:${NC}"
        echo -e "${YELLOW}Możesz podać:${NC}"
        echo -e "${WHITE}• Pełną nazwę (np. 12345.nazwa_sesji)${NC}"
        echo -e "${WHITE}• Skróconą nazwę (np. nazwa_sesji)${NC}"
        echo -e "${WHITE}• Samo ID (np. 12345)${NC}"
        echo
        read -p "$(echo -e ${CYAN}Nazwa/ID sesji [Enter = anuluj]:${NC} )" session_input
        
        if [ -z "$session_input" ]; then
            echo -e "${BLUE}Anulowano wznowienie sesji.${NC}"
            read -p "$(echo -e ${WHITE}Naciśnij Enter, aby kontynuować...${NC})"
            return
        else
            session_id="$session_input"
        fi
    fi
    
    show_loading_bar 1 "Sprawdzanie dostępności sesji '$session_id'..."
    
    # Sprawdzenie czy sesja istnieje i jest odłączona
    if screen -ls | grep -q "$session_id.*(Detached)"; then
        echo -e "${GREEN}✅ Sesja '$session_id' jest dostępna. Dołączanie...${NC}"
        echo -e "${YELLOW}🔧 Użyj Ctrl+A, następnie D aby odłączyć się od sesji${NC}"
        echo
        sleep 1
        screen -r "$session_id"
    elif screen -ls | grep -q "$session_id.*(Attached)"; then
        echo -e "${YELLOW}⚠️  Sesja '$session_id' jest już aktywnie używana (Attached).${NC}"
        echo
        echo -e "${WHITE}Co chcesz zrobić?${NC}"
        echo -e "${GREEN}[1]${NC} Wymuś dołączenie (odłączy innych użytkowników)"
        echo -e "${BLUE}[2]${NC} Anuluj i powróć do menu"
        echo
        read -p "$(echo -e ${CYAN}Twój wybór [1-2]:${NC} )" force_choice
        
        case $force_choice in
            1)
                echo -e "${YELLOW}Wymuszanie dołączenia...${NC}"
                screen -dr "$session_id"
                ;;
            2)
                echo -e "${BLUE}Anulowano.${NC}"
                ;;
            *)
                echo -e "${RED}Nieprawidłowy wybór.${NC}"
                ;;
        esac
    else
        echo -e "${RED}❌ Sesja '$session_id' nie istnieje lub nie jest dostępna.${NC}"
        echo -e "${YELLOW}Sprawdź listę dostępnych sesji (opcja 2 w menu).${NC}"
    fi
    
    echo
    read -p "$(echo -e ${WHITE}Naciśnij Enter, aby kontynuować...${NC})"
}

# Funkcja zamykająca sesję
kill_screen_session() {
    echo -e "${WHITE}${BOLD}❌ ZAMYKANIE SESJI SCREEN${NC}"
    echo -e "${PURPLE}─────────────────────────────────────────────────────────────────────────────${NC}"
    
    # Wyświetlenie dostępnych sesji
    local sessions_output=$(screen -ls 2>&1)
    
    if echo "$sessions_output" | grep -q "No Sockets found"; then
        echo -e "${YELLOW}📭 Brak aktywnych sesji Screen do zamknięcia.${NC}"
        echo
        read -p "$(echo -e ${WHITE}Naciśnij Enter, aby kontynuować...${NC})"
        return
    fi
    
    echo -e "${CYAN}Dostępne sesje do zamknięcia:${NC}"
    echo
    echo "$sessions_output" | grep -E "^\s*[0-9]+\." | nl -w2 -s') '
    echo
    
    echo -e "${RED}⚠️  UWAGA: Ta operacja definitywnie zamknie wybraną sesję!${NC}"
    echo -e "${YELLOW}Wszystkie niezapisane dane w sesji zostaną utracone.${NC}"
    echo
    
    read -p "$(echo -e ${CYAN}Nazwa/ID sesji do zamknięcia [Enter = anuluj]:${NC} )" session_id
    
    if [ -z "$session_id" ]; then
        echo -e "${BLUE}Anulowano zamykanie sesji.${NC}"
        echo
        read -p "$(echo -e ${WHITE}Naciśnij Enter, aby kontynuować...${NC})"
        return
    fi
    
    # Potwierdzenie
    echo -e "${RED}Czy na pewno chcesz zamknąć sesję '$session_id'? [tak/NIE]:${NC}"
    read confirmation
    
    if [[ "$confirmation" =~ ^(tak|TAK|yes|YES|y|Y)$ ]]; then
        show_loading_bar 1.5 "Zamykanie sesji '$session_id'..."
        
        screen -X -S "$session_id" quit 2>/dev/null
        
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}✅ Sesja '$session_id' została pomyślnie zamknięta.${NC}"
        else
            echo -e "${RED}❌ Nie udało się zamknąć sesji '$session_id'.${NC}"
            echo -e "${YELLOW}Sprawdź czy nazwa/ID sesji jest prawidłowa.${NC}"
        fi
    else
        echo -e "${BLUE}Anulowano zamykanie sesji.${NC}"
    fi
    
    echo
    read -p "$(echo -e ${WHITE}Naciśnij Enter, aby kontynuować...${NC})"
}

# Funkcja pomocy
show_help() {
    echo -e "${WHITE}${BOLD}ℹ️  POMOC I INSTRUKCJE${NC}"
    echo -e "${PURPLE}─────────────────────────────────────────────────────────────────────────────${NC}"
    echo
    echo -e "${CYAN}${BOLD}🎯 CEL SKRYPTU:${NC}"
    echo -e "${WHITE}Ten skrypt ułatwia zarządzanie sesjami GNU Screen dla dowolnych aplikacji.${NC}"
    echo -e "${WHITE}Screen pozwala uruchamiać aplikacje w tle i łączyć się z nimi w dowolnym momencie.${NC}"
    echo
    echo -e "${CYAN}${BOLD}📋 DOSTĘPNE OPCJE MENU:${NC}"
    echo
    echo -e "${GREEN}[1] 🚀 Uruchom nową sesję Screen z komendą${NC}"
    echo -e "${WHITE}    • Tworzy nową sesję Screen o wybranej nazwie.${NC}"
    echo -e "${WHITE}    • Uruchamia podaną komendę w tej sesji (np. 'honcho start', 'python app.py', 'npm start').${NC}"
    echo -e "${WHITE}    • Sesja działa w tle, nawet po zamknięciu terminala.${NC}"
    echo
    echo -e "${BLUE}[2] 📋 Wyświetl aktywne sesje${NC}"
    echo -e "${WHITE}    • Pokazuje wszystkie aktywne sesje Screen.${NC}"
    echo -e "${WHITE}    • Wyświetla status sesji (Attached/Detached).${NC}"
    echo -e "${WHITE}    • Pomaga zidentyfikować dostępne sesje.${NC}"
    echo
    echo -e "${YELLOW}[3] 🔄 Wznów istniejącą sesję${NC}"
    echo -e "${WHITE}    • Dołącza do wcześniej utworzonej sesji.${NC}"
    echo -e "${WHITE}    • Pozwala na interakcję z działającą aplikacją.${NC}"
    echo -e "${WHITE}    • Można podać nazwę lub ID sesji.${NC}"
    echo
    echo -e "${RED}[4] ❌ Zamknij sesję${NC}"
    echo -e "${WHITE}    • Definitywnie kończy wybraną sesję Screen.${NC}"
    echo -e "${WHITE}    • UWAGA: Zamyka również działające w niej aplikacje.${NC}"
    echo -e "${WHITE}    • Wymaga potwierdzenia przed wykonaniem.${NC}"
    echo
    echo -e "${PURPLE}[5] 📊 Status systemu${NC}"
    echo -e "${WHITE}    • Sprawdza dostępność wymaganych narzędzi (Screen).${NC}"
    echo -e "${WHITE}    • Wyświetla informacje o systemie.${NC}"
    echo -e "${WHITE}    • Pokazuje wykorzystanie zasobów.${NC}"
    echo
    echo -e "${CYAN}${BOLD}⌨️  PRZYDATNE SKRÓTY KLAWISZOWE W SESJI SCREEN:${NC}"
    echo -e "${WHITE}• Ctrl+A, następnie D      → Odłącz się od sesji (sesja nadal działa)${NC}"
    echo -e "${WHITE}• Ctrl+A, następnie K      → Zabij bieżącą sesję${NC}"
    echo -e "${WHITE}• Ctrl+A, następnie ?      → Wyświetl pomoc Screen${NC}"
    echo -e "${WHITE}• Ctrl+C                    → Przerwij działającą aplikację w sesji${NC}"
    echo -e "${WHITE}• exit lub Ctrl+D           → Zamknij sesję Shell (i sesję Screen, jeśli to ostatnie okno)${NC}"
    echo
    echo -e "${CYAN}${BOLD}🔧 ROZWIĄZYWANIE PROBLEMÓW:${NC}"
    echo
    echo -e "${YELLOW}Problem: 'screen: command not found'${NC}"
    echo -e "${WHITE}Rozwiązanie: Zainstaluj Screen używając:${NC}"
    echo -e "${WHITE}• Ubuntu/Debian: sudo apt install screen${NC}"
    echo -e "${WHITE}• RHEL/CentOS: sudo yum install screen${NC}"
    echo -e "${WHITE}• Arch Linux: sudo pacman -S screen${NC}"
    echo
    echo -e "${YELLOW}Problem: Komenda nie działa w sesji Screen${NC}"
    echo -e "${WHITE}Rozwiązanie: Upewnij się, że:${NC}"
    echo -e "${WHITE}• Komenda jest poprawna i działa w zwykłym terminalu.${NC}"
    echo -e "${WHITE}• Środowisko wirtualne jest aktywowane (jeśli używasz) PRZED uruchomieniem skryptu lub w samej komendzie (np. 'source venv/bin/activate && honcho start').${NC}"
    echo -e "${WHITE}• Pełna ścieżka do komendy jest podana, jeśli nie jest w PATH.${NC}"
    echo
    echo -e "${YELLOW}Problem: Nie można dołączyć do sesji${NC}"
    echo -e "${WHITE}Rozwiązanie:${NC}"
    echo -e "${WHITE}• Sprawdź czy sesja istnieje (opcja 2)${NC}"
    echo -e "${WHITE}• Upewnij się że sesja jest w stanie 'Detached'${NC}"
    echo -e "${WHITE}• Użyj pełnej nazwy sesji (np. 12345.moja_sesja)${NC}"
    echo
    echo -e "${CYAN}${BOLD}📞 WSPARCIE:${NC}"
    echo -e "${WHITE}W przypadku problemów sprawdź:${NC}"
    echo -e "${WHITE}• Dokumentację GNU Screen: man screen${NC}"
    echo -e "${WHITE}• Logi systemowe: journalctl -u screen${NC}"
    echo
    echo -e "${PURPLE}─────────────────────────────────────────────────────────────────────────────${NC}"
    echo
    read -p "$(echo -e ${WHITE}Naciśnij Enter, aby powrócić do menu...${NC})"
}

# Funkcja obsługująca wybór użytkownika
handle_user_choice() {
    local choice=$1
    
    case $choice in
        1)
            start_new_session
            ;;
        2)
            list_screen_sessions
            ;;
        3)
            resume_screen_session
            ;;
        4)
            kill_screen_session
            ;;
        5)
            show_system_status
            read -p "$(echo -e ${WHITE}Naciśnij Enter, aby kontynuować...${NC})"
            ;;
        6)
            show_help
            ;;
        0)
            echo -e "${GREEN}👋 Dziękujemy za użycie Menedżera Sesji Screen!${NC}"
            echo -e "${CYAN}Do zobaczenia!${NC}"
            exit 0
            ;;
        *)
            echo -e "${RED}❌ Nieprawidłowy wybór. Spróbuj ponownie.${NC}"
            sleep 1
            ;;
    esac
}

# Funkcja główna pętla programu
main_loop() {
    while true; do
        show_header
        show_main_menu
        
        read -p "$(echo -e ${CYAN}Wybierz opcję [0-6]:${NC} )" choice
        echo
        
        handle_user_choice "$choice"
        
        # Krótka pauza przed następną iteracją
        sleep 0.5
    done
}

# ═══════════════════════════════════════════════════════════════════════════════
# URUCHOMIENIE PROGRAMU
# ═══════════════════════════════════════════════════════════════════════════════

# Sprawdzenie czy skrypt jest uruchamiany interaktywnie
if [ $# -eq 0 ]; then
    # Tryb interaktywny
    main_loop
else
    # Tryb kompatybilności wstecznej (stare argumenty)
    case "$1" in
        start)
            # W trybie argumentów, 'start' wymaga nazwy sesji i komendy
            if [ -z "$2" ] || [ -z "$3" ]; then
                echo -e "${RED}❌ Błąd: Dla 'start' w trybie argumentów wymagana jest nazwa sesji i komenda.${NC}"
                echo -e "${YELLOW}Użycie: $0 start <nazwa_sesji> \"<komenda_do_uruchomienia>\"${NC}"
                echo -e "${CYAN}Przykład: $0 start my_web_app \"honcho start\"${NC}"
                exit 1
            fi
            start_new_session "$2" "$3"
            ;;
        ls|list)
            list_screen_sessions
            ;;
        resume|attach)
            if [ -z "$2" ]; then
                echo -e "${RED}❌ Błąd: Dla 'resume'/'attach' w trybie argumentów wymagana jest nazwa/ID sesji.${NC}"
                echo -e "${YELLOW}Użycie: $0 resume <nazwa_sesji_lub_ID>${NC}"
                exit 1
            fi
            resume_screen_session "$2"
            ;;
        kill|stop)
            if [ -z "$2" ]; then
                echo -e "${RED}❌ Błąd: Dla 'kill'/'stop' w trybie argumentów wymagana jest nazwa/ID sesji.${NC}"
                echo -e "${YELLOW}Użycie: $0 kill <nazwa_sesji_lub_ID>${NC}"
                exit 1
            fi
            kill_screen_session "$2"
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            echo -e "${RED}Nieznany argument: $1${NC}"
            echo -e "${WHITE}Dostępne argumenty: start, ls, list, resume, attach, kill, stop, help${NC}"
            echo -e "${CYAN}Uruchom bez argumentów, aby użyć interaktywnego menu.${NC}"
            exit 1
            ;;
    esac
fi
