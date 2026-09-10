# VozLivre

**Ditado por voz para macOS, 100% local — feito para quem fala português misturado com inglês.**

> Falar é mais rápido do que digitar.

Aperta Caps Lock duas vezes, fala, aperta de novo. O texto aparece onde o cursor estiver —
em qualquer app. Nada sai do seu Mac.

---

## Por que existe

Ditado genérico entende português. O que ele não entende é **como a gente fala de verdade**:

> "faz o **deploy** do **build** e manda no **Slack**"
> "o **webhook** do **Stripe** deu **timeout** de novo"

Um ditado que só sabe português tenta escrever esses termos foneticamente. "webhook" vira
"e-book", "rollback" vira "um roubo aqui", "timeout" vira "time out". O VozLivre recebe uma
dica de vocabulário antes de cada ditado dizendo que termos técnicos ficam em inglês — e
você pode acrescentar as suas próprias palavras.

Medido em 12 frases, 34 termos, duas vozes:

| | antes | depois |
|---|---|---|
| Termos em inglês corretos | 75% | **94%** |

## Como está hoje

| | |
|---|---|
| Tempo da fala até o texto | **~750 ms** |
| Taxa de erro (áudio limpo) | **3,8%** |
| Taxa de erro (com ruído de fundo) | 11,5% |
| Tamanho do app | 1,0 GB |
| Memória em uso | ~1,8 GB, liberada sozinha após 10 min parado |
| Rede | **nenhuma** |

## O que ele faz

- **Mãos livres.** Dois toques rápidos no Caps Lock ligam e desligam a escuta. Nada de
  segurar tecla. Como dois toques são duas inversões, o Caps Lock volta exatamente como
  estava — sem maiúscula presa.
- **Você vê que ele está ouvindo.** Uma pílula flutuante mostra a onda da sua voz ao vivo,
  em cima de qualquer app, sem roubar o foco do teclado.
- **Não inventa texto no silêncio.** Modelos Whisper preenchem silêncio com frases de
  legenda de vídeo ("Legenda por…", "Inscreva-se no canal…"). Um detector de fala corta o
  silêncio antes, então silêncio devolve silêncio.
- **Vocabulário seu.** Menu → "Meu vocabulário…" — uma palavra por linha.
- **Atalho configurável.** Duplo toque em qualquer modificador, modificador segurado
  (push-to-talk) ou tecla de função.

## Requisitos

- macOS 26 ou superior, Apple Silicon
- Xcode Command Line Tools, `cmake` (`brew install cmake`)
- ~4 GB livres durante a preparação, ~1 GB depois

## Instalação

```bash
git clone https://github.com/edneyjunior-2/vozlivre.git
cd vozlivre
./scripts/preparar.sh          # compila o motor e baixa os modelos (~1 GB)
./scripts/montar-e-instalar.sh # monta o .app, instala e abre
```

Na primeira execução o macOS vai pedir **Microfone** e **Acessibilidade** (essa segunda é
necessária para escrever o texto no app onde você está).

## Privacidade

O reconhecimento roda inteiro dentro do seu Mac:

- Não há **nenhuma** chamada de rede no código do app.
- O modelo de reconhecimento (1 GB) fica dentro do próprio `.app`.
- O áudio vira um arquivo temporário só o tempo de ser processado e é apagado em seguida.
- **Funciona em modo avião.**

## Como funciona por dentro

```
Caps Lock 2×  →  AVAudioEngine grava       →  detector de fala corta o silêncio
                 (e alimenta a onda da UI)     →  Whisper large-v3 (comprimido) + dica
                                                   de vocabulário  →  texto no cursor
```

O motor ([whisper.cpp](https://github.com/ggml-org/whisper.cpp)) é linkado como biblioteca
**dentro do processo**, não chamado como programa externo. O modelo carrega uma vez e é
reaproveitado; a carga começa no instante em que a gravação começa, então acontece
enquanto você ainda está falando e some da espera. Depois de 10 minutos parado — ou assim
que o macOS avisa que está com pouca memória — o modelo é solto.

## Decisões medidas (e o que foi descartado)

Tudo abaixo foi testado num M5 de 16 GB antes de ser aceito ou rejeitado.

| Ideia | Resultado | Decisão |
|---|---|---|
| Comprimir o modelo (q5_0) | 2,88 GB → 1,01 GB, **mesma** taxa de erro | ✅ adotado |
| Detector de fala (Silero VAD) | eliminou 100% das frases inventadas em silêncio | ✅ adotado |
| Dica de vocabulário no prompt | termos em inglês: 75% → 94% | ✅ adotado |
| Motor como biblioteca, não processo | tira a carga do modelo da espera | ✅ adotado |
| Comprimir mais (q4_0) | erro sobe de 3,8% → 5,8%, economiza só 180 MB | ❌ |
| Encurtar a janela de 30s (`audio_ctx`) | quase dobra o erro (3,8% → 6,7%) | ❌ |
| Neural Engine via Core ML | soma 1,2 GB ao app; o "3× mais rápido" é vs. CPU, não vs. GPU | ❌ |
| Trocar para large-v3-turbo | 2× mais rápido, mas erra 4 dos 8 termos em inglês (vs. 1) | ❌ |
| Trocar para Parakeet | não aceita vocabulário customizado — perde o motivo do projeto | ❌ |
| `-mc 0` (sem contexto) | **desliga o prompt inteiro** no whisper.cpp — anula o vocabulário | ⚠️ armadilha |

## Banco de provas

```bash
swift build --product TesteMotor -c release
./.build/release/TesteMotor Vendor/whisper/ggml-large-v3-q5_0.bin \
                            Vendor/whisper/ggml-silero-v5.1.2.bin \
                            seu-audio.wav
```

Reporta carga do modelo, tempo de transcrição com o modelo já residente, e verifica que
silêncio devolve vazio.

## Créditos

- [whisper.cpp](https://github.com/ggml-org/whisper.cpp) — motor de inferência (MIT)
- [Whisper](https://github.com/openai/whisper) da OpenAI — modelo large-v3 (MIT)
- [Silero VAD](https://github.com/snakers4/silero-vad) — detecção de fala

## Licença

MIT — veja [LICENSE](LICENSE).
