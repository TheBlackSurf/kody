#!/bin/bash

# Nazwa pliku wyjściowego PDF
OUTPUT_PDF="izolka_project_source_code.pdf"
# Plik tymczasowy do przechowywania listy ścieżek do plików źródłowych
FILE_LIST_TMP="source_files_list.txt"
# Plik tymczasowy Markdown, który będzie zawierał cały zagregowany kod
MERGED_MD_FILE="consolidated_source_code.md"

echo "Rozpoczynam generowanie PDF z kodem źródłowym projektu Izolka..."

# Wyczyść poprzednie pliki tymczasowe, jeśli istnieją
rm -f "$FILE_LIST_TMP" "$MERGED_MD_FILE"

# 1. Wyszukiwanie plików źródłowych
#    Dostosuj ścieżki i wykluczenia w sekcji -not -path do struktury swojego projektu.
echo "Wyszukiwanie plików źródłowych (.py, .html, .js)..."
find . \
    \( -name "*.py" -o -name "*.html" -o -name "*.js" \) \
    -not -path "./.venv/*" \
    -not -path "*/__pycache__/*" \
    -not -path "./staticfiles/*" \
    -not -path "./media/*" \
    -not -path "./avatars/*" \
    -not -path "*/node_modules/*" \
    -not -path "./.git/*" \
    -not -name "db_backu.sqlite3" \
    -not -name "identifier.sqlite" \
    -not -name "$OUTPUT_PDF" \
    -not -name "$FILE_LIST_TMP" \
    -not -name "$MERGED_MD_FILE" \
    -type f \
    > "$FILE_LIST_TMP"

if [ ! -s "$FILE_LIST_TMP" ]; then
    echo "Nie znaleziono żadnych plików źródłowych pasujących do kryteriów."
    echo "Sprawdź ścieżki i wykluczenia w skrypcie."
    exit 1
fi

echo "Znaleziono $(wc -l < "$FILE_LIST_TMP") plików źródłowych."
echo "Lista plików do przetworzenia zapisana w: $FILE_LIST_TMP"

# 2. Przygotowanie jednego pliku Markdown z zawartością wszystkich plików
echo "# Kod Źródłowy Projektu Izolka" > "$MERGED_MD_FILE"
echo "" >> "$MERGED_MD_FILE"
echo "\\newpage" >> "$MERGED_MD_FILE" # Opcjonalnie: spis treści na osobnej stronie
echo "" >> "$MERGED_MD_FILE"

# Dodanie informacji o dacie generacji
echo "**Data generacji:** $(date)" >> "$MERGED_MD_FILE"
echo "" >> "$MERGED_MD_FILE"
echo "\\newpage" >> "$MERGED_MD_FILE" # Zaczynamy listę plików na nowej stronie

while IFS= read -r filepath; do
    echo "Przetwarzanie pliku: $filepath"

    # Usunięcie './' z początku ścieżki dla lepszej prezentacji
    display_filepath="${filepath#./}"
    extension="${filepath##*.}"
    lang="$extension" # Domyślny język to rozszerzenie

    # Mapowanie rozszerzeń na języki rozpoznawane przez Pandoc dla kolorowania składni
    if [ "$extension" = "py" ]; then
        lang="python"
    elif [ "$extension" = "js" ]; then
        lang="javascript"
    elif [ "$extension" = "html" ]; then
        lang="html"
    fi

    echo "" >> "$MERGED_MD_FILE"
    # Użycie mniejszego nagłówka dla nazwy pliku
    echo "### Plik: \`$display_filepath\`" >> "$MERGED_MD_FILE"
    echo "" >> "$MERGED_MD_FILE"
    echo "\`\`\`$lang" >> "$MERGED_MD_FILE"
    # Dodanie zawartości pliku, upewniając się, że jest poprawnie zinterpretowana przez cat
    if ! cat "$filepath" >> "$MERGED_MD_FILE"; then
        echo "Ostrzeżenie: Nie udało się odczytać pliku $filepath"
    fi
    echo "" >> "$MERGED_MD_FILE" # Dodatkowa nowa linia dla pewności przed zamknięciem bloku kodu
    echo "\`\`\`" >> "$MERGED_MD_FILE"
    echo "" >> "$MERGED_MD_FILE"
    # Opcja \\newpage: umieszcza każdy plik na nowej stronie. Usuń lub zakomentuj, jeśli nie jest to pożądane.
    echo "\\newpage" >> "$MERGED_MD_FILE"

done < "$FILE_LIST_TMP"

echo "Wygenerowano tymczasowy plik markdown: $MERGED_MD_FILE"

# 3. Konwersja pliku Markdown do PDF za pomocą pandoc
echo "Rozpoczynam konwersję $MERGED_MD_FILE do $OUTPUT_PDF..."
pandoc "$MERGED_MD_FILE" -o "$OUTPUT_PDF" --from markdown --highlight-style=kate \
  -V geometry:a4paper,margin=1in -V fontsize=8pt --pdf-engine=xelatex \
  --toc --toc-depth=2 --resource-path="." --listings # <--- DODANO --listings

# Możliwe silniki PDF: pdflatex, xelatex, lualatex. xelatex lepiej radzi sobie z Unicode.
# Jeśli wystąpią problemy z pdflatex (np. z polskimi znakami w kodzie), rozważ xelatex
# lub spróbuj z pdflatex (upewnij się, że masz odpowiednie pakiety LaTeX):
# pandoc "$MERGED_MD_FILE" -o "$OUTPUT_PDF" --from markdown --highlight-style=kate \
#   -V geometry:a4paper,margin=1in -V fontsize=8pt --pdf-engine=pdflatex \
#   --toc --toc-depth=2 --resource-path="." --listings

if [ $? -eq 0 ]; then
    echo "Pomyślnie wygenerowano PDF: $OUTPUT_PDF"
    echo "Rozmiar pliku: $(du -h "$OUTPUT_PDF" | cut -f1)"
else
    echo "Wystąpił błąd podczas generowania PDF."
    echo "Upewnij się, że pandoc oraz silnik LaTeX (np. pdflatex/xelatex z potrzebnymi pakietami, w tym 'listings') są poprawnie zainstalowane."
    echo "Sprawdź logi błędów pandoc/LaTeX."
    echo "Możliwe problemy:"
    echo "  - Brakujące pakiety LaTeX (np. 'amsfonts', 'amsmath', 'lm', 'ifluatex', 'unicode-math', 'fancyvrb', 'upquote', 'microtype', 'listings')."
    echo "  - Znaki w kodzie źródłowym nieobsługiwane przez wybrany silnik LaTeX (rozważ --pdf-engine=xelatex)."
    echo "  - Zbyt długie nieprzerwane linie kodu (opcja --listings powinna pomóc)."
    echo "  - Jeśli błąd 'Dimension too large' nadal występuje z --listings, rozważ dodatkowe opcje listings: "
    echo "    '-V \"listingsoptions:breaklines=true,breakatwhitespace=false\"' do polecenia pandoc."
    exit 1
fi

# 4. Sprzątanie plików tymczasowych
echo "Czyszczenie plików tymczasowych..."
rm "$FILE_LIST_TMP"
rm "$MERGED_MD_FILE"

echo "Zakończono pomyślnie."