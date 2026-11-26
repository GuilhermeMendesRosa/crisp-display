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

**HiDPI:** o macOS desenha tudo em 2x (1344x756 vira 2688x1512) e reduz para a resolução nativa do painel. Fica com o tamanho de 1344x756, mas com texto bem mais nítido. Há dois caminhos, nesta ordem:

1. **Modo do próprio monitor.** Se o monitor já oferece o modo HiDPI pedido, o `crisp-display` aplica esse modo direto e reaplica sempre que o monitor reconecta. É o melhor caminho: sem tela virtual e sem espelhamento, o cursor passa entre os monitores sem travar.
2. **Tela virtual.** Se o modo não existir, ele cria uma tela virtual com o dobro dos pixels (API `CGVirtualDisplay` do CoreGraphics) e coloca o monitor físico para espelhá-la.
   - O monitor desconectou? A tela virtual some junto, então nenhuma janela fica presa numa tela fantasma.
   - O monitor reconectou? Ele volta a espelhar sozinho.
   - O processo morreu? O macOS desfaz o espelhamento e o monitor volta ao normal.

O `crisp-display list` mostra qual caminho está valendo: no espelhamento, o monitor aparece como `espelhando N`.

**Trava da Dock:** o macOS leva a Dock para qualquer monitor em cuja borda de baixo o mouse encosta, o que atrapalha quando o monitor pequeno fica embaixo do grande. O `crisp-display` não deixa o cursor chegar à última linha de pixels dessa borda nos monitores secundários. Assim a Dock nunca sai do principal. Bordas encostadas em outro monitor continuam livres. Também funciona com a Dock na esquerda ou na direita.

- O macOS segura o cursor por um instante na borda onde fica a Dock. Se houver um monitor do outro lado e o cursor estiver indo para ele, a trava faz o cursor passar direto.
- Se a Dock voltar para o principal mas o macOS continuar reservando o espaço dela no secundário (janelas centralizadas lá ficam com uma faixa vazia embaixo), a trava liga e desliga o "ocultar Dock" uma vez para o macOS recalcular.

### Permissões

- **Acessibilidade** (Ajustes do Sistema > Privacidade e Segurança > Acessibilidade): a trava corrige cada movimento do mouse antes de o macOS aplicá-lo, com um event tap, como faz o [DockPin](https://github.com/green2grey/DockPin) (MIT). Sem a permissão, ela corrige depois de o cursor se mover, o que funciona mas pode dar pequenas travadas. O log mostra qual modo está valendo.
- **Automação** (System Events): só para recalcular o espaço reservado da Dock. É pedida na primeira vez que for preciso.

O macOS amarra essas permissões ao binário. Depois de recompilar e reinstalar, remova o `crisp-display` da lista de Acessibilidade e adicione de novo (`~/.local/bin/crisp-display`, use Cmd+Shift+G no seletor de arquivos).

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
make install DISPLAY_ID=7908:320 LOOKS_LIKE=1344x756 POSITION=below
```

Isso copia o binário para `~/.local/bin` e cria um LaunchAgent que abre no login e reinicia sozinho se cair.

| Variável     | Padrão     | O que faz                                                    |
| ------------ | ---------- | ------------------------------------------------------------ |
| `DISPLAY_ID` | (vazio)    | Monitor que vai ganhar HiDPI. Vazio liga só a trava da Dock. |
| `LOOKS_LIKE` | `1344x756` | Tamanho da interface. Menor deixa tudo maior.                |
| `POSITION`   | (vazio)    | `below`, `above`, `left` ou `right`: mantém o monitor HiDPI encostado nesse lado do principal. Sem ela, quem decide é o macOS. |
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

- O modo HiDPI próprio nem sempre existe: monitores 1080p normalmente não oferecem esse modo, e aí vale a tela virtual.
- `CGVirtualDisplay` é uma API privada da Apple. Ela existe desde o macOS 11 e é usada por vários apps, mas pode mudar numa atualização do sistema.
- O espelhamento (só no caminho da tela virtual) adiciona uma etapa de redimensionamento na GPU. É imperceptível no uso normal, mas pode adicionar um pouco de latência em jogos.
- Mudar a resolução da tela virtual em Ajustes do Sistema vale até o monitor reconectar. Para mudar de vez, use `LOOKS_LIKE`.
- Com a trava da Dock ligada, a última linha de pixels da borda dos monitores secundários fica inacessível.
- A trava impede a Dock de sair do principal, mas não consegue trazer ela de volta: a Dock só troca de monitor com movimento real do mouse. Se ela já estiver num secundário (por exemplo, porque o serviço estava parado), empurre o mouse contra a borda de baixo do monitor principal, num trecho que não tenha outro monitor embaixo.

## Licença

[MIT](LICENSE)
