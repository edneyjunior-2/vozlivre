# Origem dos cabeçalhos

Os arquivos `.h` em `include/` (exceto `CWhisper.h`) são cópias sem modificação dos
cabeçalhos públicos do [whisper.cpp](https://github.com/ggml-org/whisper.cpp),
versão **v1.9.1**, distribuídos sob a **licença MIT** por Georgi Gerganov e
contribuidores.

Eles ficam versionados aqui para que `swift build` funcione sem depender da ordem de
execução do `scripts/preparar.sh`. Esse script sobrescreve estes arquivos com os
cabeçalhos da versão que ele compila — se você mudar `VERSAO_WHISPER` lá, estes
arquivos são atualizados junto.

As bibliotecas compiladas (`libwhisper.a` e as do ggml) **não** estão no repositório;
são geradas localmente pelo `preparar.sh` em `Vendor/whisper-lib/`.
