<h1 align="center">crisp-display</h1>

<p align="center">HiDPI nítido em monitores 1080p no macOS, e Dock presa no monitor principal. Sem app de terceiros, só uma ferramenta de linha de comando.</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/github/license/GuilhermeMendesRosa/crisp-display" alt="Licença MIT"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-black?logo=apple" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Apple%20Silicon-sim-black" alt="Apple Silicon">
</p>

## O problema

Num monitor portátil de 14" com 1080p, o macOS te deixa com duas opções ruins:

- **1920x1080 nativo:** nítido, mas tudo minúsculo.
- **Uma resolução menor, como 1280x720:** tamanho bom, mas a imagem fica pixelada.

Isso acontece porque o macOS só oferece os modos **HiDPI** (a interface desenhada em 2x, como numa tela Retina) para monitores de alta resolução.

## Como funciona

**HiDPI:** o `crisp-display` cria uma tela virtual com o dobro dos pixels do tamanho que você quer (1344x756 vira 2688x1512) e coloca o monitor físico para espelhá-la. O macOS desenha tudo em 2x e a GPU reduz para a resolução nativa do painel. Fica com o tamanho de 1344x756, mas com texto bem mais nítido. A tela virtual usa a API `CGVirtualDisplay` do CoreGraphics.

- O monitor desconectou? A tela virtual some junto, então nenhuma janela fica presa numa tela fantasma.
- O monitor reconectou? Ele volta a espelhar sozinho.
- O processo morreu? O macOS desfaz o espelhamento e o monitor volta ao normal.

**Trava da Dock:** o macOS leva a Dock para qualquer monitor em cuja borda de baixo o mouse encosta, o que atrapalha quando o monitor pequeno fica embaixo do grande. O `crisp-display` não deixa o cursor chegar à última linha de pixels dessa borda nos monitores secundários. Assim a Dock nunca sai do principal. Bordas encostadas em outro monitor continuam livres. Também funciona com a Dock na esquerda ou na direita.

Nenhuma das duas partes pede permissão de Acessibilidade ou de Gravação de Tela.

## Instalação

Precisa do Xcode Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/GuilhermeMendesRosa/crisp-display.git
cd crisp-display
make list
```

O `make list` mostra os monitores com o identificador `fabricante:modelo`:

```
1  7908:320  ARZOPA  interface 1920x1080, pixels 1920x1080
3  1507:9987  U27B3A  interface 1920x1080, pixels 3840x2160  principal
```

Instale apontando para o monitor que vai ganhar HiDPI:

```sh
make install DISPLAY_ID=7908:320 LOOKS_LIKE=1344x756
```

Isso copia o binário para `~/.local/bin` e cria um LaunchAgent que abre no login e reinicia sozinho se cair.

| Variável     | Padrão     | O que faz                                                    |
| ------------ | ---------- | ------------------------------------------------------------ |
| `DISPLAY_ID` | (vazio)    | Monitor que vai ganhar HiDPI. Vazio liga só a trava da Dock. |
| `LOOKS_LIKE` | `1344x756` | Tamanho da interface. Menor deixa tudo maior.                |
| `DOCK_GUARD` | `1`        | `0` desliga a trava da Dock.                                 |

Tamanhos para um monitor 16:9 de 14": `1280x720` (bem grande), `1344x756` (equilibrado), `1600x900` (mais espaço). Para trocar, rode `make install` de novo com outro `LOOKS_LIKE`.

## Comandos

```sh
make logs       # acompanha o log (~/Library/Logs/crisp-display.log)
make restart    # reinicia o serviço
make uninstall  # remove o serviço e o binário
```

Ou direto, sem instalar:

```sh
build/crisp-display run --display 7908:320 --looks-like 1344x756
```

## Limitações

- `CGVirtualDisplay` é uma API privada da Apple. Ela existe desde o macOS 11 e é usada por vários apps, mas pode mudar numa atualização do sistema.
- O espelhamento adiciona uma etapa de redimensionamento na GPU. É imperceptível no uso normal, mas pode adicionar um pouco de latência em jogos.
- Mudar a resolução da tela virtual em Ajustes do Sistema vale até o monitor reconectar. Para mudar de vez, use `LOOKS_LIKE`.
- Com a trava da Dock ligada, a última linha de pixels da borda dos monitores secundários fica inacessível.

## Licença

[MIT](LICENSE)
