#!/bin/bash
# Prepara tudo que o VozLivre precisa e que não cabe no Git:
#   1. compila o whisper.cpp como biblioteca estática (com Metal)
#   2. baixa o modelo de transcrição e o de detecção de fala
# Roda uma vez só. Precisa de: cmake, git, curl e as ferramentas de linha de
# comando do Xcode.
set -e

PROJ="$(cd "$(dirname "$0")/.." && pwd)"
VERSAO_WHISPER="v1.9.1"
TRABALHO="$PROJ/.preparar"
LIB="$PROJ/Vendor/whisper-lib"
MODELOS="$PROJ/Vendor/whisper"

command -v cmake >/dev/null || { echo "❌ cmake não encontrado. Instale com: brew install cmake"; exit 1; }

echo "==> 1/3 Baixando o whisper.cpp $VERSAO_WHISPER…"
mkdir -p "$TRABALHO"
if [ ! -d "$TRABALHO/whispercpp" ]; then
  git clone --depth 1 --branch "$VERSAO_WHISPER" https://github.com/ggml-org/whisper.cpp "$TRABALHO/whispercpp"
fi

echo "==> 2/3 Compilando o motor como biblioteca (Metal embutido)…"
cd "$TRABALHO/whispercpp"
cmake -B build-static \
  -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON \
  -DBUILD_SHARED_LIBS=OFF \
  -DWHISPER_BUILD_EXAMPLES=OFF -DWHISPER_BUILD_TESTS=OFF \
  -DCMAKE_BUILD_TYPE=Release > /dev/null
cmake --build build-static -j"$(sysctl -n hw.ncpu)" --config Release > /dev/null

mkdir -p "$LIB/lib" "$LIB/include"
find build-static -name "*.a" ! -name "libcommon.a" ! -name "libparakeet.a" \
  -exec cp {} "$LIB/lib/" \;
cp include/whisper.h "$LIB/include/"
cp ggml/include/*.h "$LIB/include/"
# Os mesmos cabeçalhos precisam estar visíveis ao alvo C do SwiftPM.
cp "$LIB/include/"*.h "$PROJ/Sources/CWhisper/include/"

echo "==> 3/3 Baixando os modelos (~1 GB)…"
mkdir -p "$MODELOS"
BASE="https://huggingface.co"
if [ ! -f "$MODELOS/ggml-large-v3-q5_0.bin" ]; then
  echo "    modelo de transcrição (large-v3 q5_0, 1,01 GB)…"
  curl -L --progress-bar -o "$MODELOS/ggml-large-v3-q5_0.bin" \
    "$BASE/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-q5_0.bin"
fi
if [ ! -f "$MODELOS/ggml-silero-v5.1.2.bin" ]; then
  echo "    detector de fala (Silero, 885 KB)…"
  curl -L --progress-bar -o "$MODELOS/ggml-silero-v5.1.2.bin" \
    "$BASE/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin"
fi

echo
echo "✅ Pronto. Agora rode: ./scripts/montar-e-instalar.sh"
