#!/bin/bash

# Usuwa i odtwarza release 'latest' z bieżącego miesiąca (HEAD).
# Używać gdy chcemy podbić datę taga i Source code bez zmiany wersji.
# Gwiazdki repozytorium NIE są tracone -- są na repo, nie na release.

REPO_DIR="/c/Projekty/github/WSAPatch"
REPO="wesmar/WSAPatch"
TAG="latest"
DATE=$(date +"%m.%Y")

cd "$REPO_DIR" || { echo "❌ Nie można przejść do: $REPO_DIR"; exit 1; }

echo "======================================"
echo "🔧 KROK 1: Pakowanie plików"
echo "======================================"
./pack-data.sh
if [ $? -ne 0 ]; then
    echo "❌ Błąd pakowania!"
    exit 1
fi

SIZE_7Z=$(du -h "WSAPatch.7z" | cut -f1)

if [ ! -f "$REPO_DIR/release-now.md" ]; then
    echo "❌ Brak pliku release-now.md"
    exit 1
fi

COMMIT=$(git log --oneline -1)
echo ""
echo "======================================"
echo "📦 WSAPatch.7z   $SIZE_7Z"
echo "🎯 Release: $TAG @ $REPO"
echo "🗓️  Data:    $DATE"
echo "🔖 Commit:  $COMMIT"
echo "======================================"
echo ""
echo "⚠️  Usuwa i odtwarza tag '$TAG' (Source code pokaże datę $DATE)."
echo "   Licznik pobrań zostanie wyzerowany."
read -r -p "Kontynuować? [t/N] " confirm
[[ "$confirm" =~ ^[tTyY]$ ]] || { echo "Anulowano."; exit 0; }

echo ""
echo "======================================"
echo "🗑️  KROK 2: Usuwanie release + tag"
echo "======================================"
gh release delete "$TAG" --repo "$REPO" --yes --cleanup-tag 2>/dev/null \
    && echo "✅ Release i tag usunięte" \
    || echo "⚠️  Release nie istniało (pierwsze tworzenie)"

echo ""
echo "======================================"
echo "📤 KROK 3: Tworzenie nowego release"
echo "======================================"

export DATE SIZE_7Z REPO TAG
RELEASE_BODY=$(envsubst '${DATE} ${SIZE_7Z} ${REPO} ${TAG}' < "$REPO_DIR/release-now.md")

gh release create "$TAG" \
    --repo "$REPO" \
    --title "WSAPatch - Release ${DATE}" \
    --notes "$RELEASE_BODY" \
    "WSAPatch.7z#WSAPatch.7z"

if [ $? -eq 0 ]; then
    echo ""
    echo "======================================"
    echo "✅ SUKCES! (${DATE})"
    echo "======================================"
    echo "   https://github.com/$REPO/releases/tag/$TAG"
    echo ""
    echo "📦 Assety:"
    echo "   WSAPatch.7z -- ${SIZE_7Z}"
else
    echo "❌ Błąd tworzenia release!"
    exit 1
fi
