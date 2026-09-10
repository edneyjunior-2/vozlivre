#!/bin/bash
# Monta o VozLivre.app, assina, instala em /Applications e abre na barra de menu.
#
# A assinatura usa a sua identidade de desenvolvedor Apple. Para descobrir a sua:
#   security find-identity -v -p codesigning
# e então exporte antes de rodar:
#   export VOZLIVRE_IDENTITY="Apple Development: Seu Nome (XXXXXXXXXX)"
# Sem isso, o script assina localmente (ad-hoc), o que funciona na sua máquina.
set -e

PROJ="$(cd "$(dirname "$0")/.." && pwd)"
APP="VozLivre.app"
BUILD_DIR="$PROJ/build"
APP_PATH="$BUILD_DIR/$APP"
IDENTITY="${VOZLIVRE_IDENTITY:--}"   # "-" = assinatura ad-hoc

cd "$PROJ"

if [ ! -d "$PROJ/Vendor/whisper-lib/lib" ]; then
  echo "❌ Motor não preparado. Rode primeiro: ./scripts/preparar.sh"
  exit 1
fi

echo "==> 1/5 Compilando (release)…"
swift build -c release --product VozLivre

echo "==> 2/5 Montando $APP…"
rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$PROJ/.build/release/VozLivre" "$APP_PATH/Contents/MacOS/VozLivre"
cp "$PROJ/Info.plist" "$APP_PATH/Contents/Info.plist"
cp "$PROJ/assets/AppIcon.icns" "$APP_PATH/Contents/Resources/AppIcon.icns"

echo "==> 3/5 Embutindo os modelos…"
cp "$PROJ/Vendor/whisper/ggml-large-v3-q5_0.bin" "$APP_PATH/Contents/Resources/"
cp "$PROJ/Vendor/whisper/ggml-silero-v5.1.2.bin" "$APP_PATH/Contents/Resources/"

echo "==> 4/5 Assinando…"
codesign --force --sign "$IDENTITY" --timestamp=none "$APP_PATH"
codesign --verify --verbose "$APP_PATH"

echo "==> 5/5 Instalando e abrindo…"
pkill -f "VozLivre.app/Contents/MacOS/VozLivre" 2>/dev/null || true
sleep 1
rm -rf "/Applications/$APP"
cp -R "$APP_PATH" "/Applications/$APP"
open "/Applications/$APP"

echo "✅ Pronto. Procure o ícone de microfone na barra de menu."
echo "   Autorize Microfone e Acessibilidade quando o macOS pedir."
