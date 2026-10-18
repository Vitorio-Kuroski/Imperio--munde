# Nota de passagem: continuar o trabalho numa sessão nova

Escrita no fim de uma longa sessão na nuvem, para continuar numa sessão que roda no computador do
usuário (Claude Desktop, pasta local). Leia antes o `CLAUDE.md`, que descreve todos os sistemas do
jogo; aqui fica só o que não está nele.

## Quem é o usuário e o que ele quer
- Fala português do Brasil; responda em português.
- Objetivo declarado: **usar os arquivos do EU4 para deixar o jogo absolutamente idêntico ao
  original** (regras, telas, mapa). Sempre que possível use os arquivos do EU4 (.gui, .gfx, defines,
  common/, history/, map/) em vez de inventar; quando algo for aproximação, diga claramente.
- Joga no celular (APK Android gerado pelo GitHub Actions) e importa o EU4 dentro do jogo
  ("Pasta do EU4..." na tela inicial). Depois de mudar um importador, lembre-o de importar de novo.
- A instalação do EU4 dele fica em `C:\Users\vitor\Downloads\JOGOS\Europa Universalis IV`.

## Repositório e regras de trabalho
- `Vitorio-Kuroski/Imperio--munde`, branch `ccr-f1dcb778-z4rh1h` (o PR #1 já foi mesclado; os
  commits seguem nesse branch, sem PR novo, a menos que ele peça). Push:
  `git push -u origin ccr-f1dcb778-z4rh1h`. Cada push roda o workflow "APK Android"; confira se passou.
- Godot 4.3. Python 3 com pillow, numpy, scipy para `tools/`.
- **Nunca commitar dados da Paradox**: `data/eu4/` e `assets/eu4/` estão no .gitignore. Nunca
  commitar `tools/data/raw/`.
- Antes de commitar, apague os arquivos gerados pelo editor/testes: `scripts/_t*.gd`,
  `scripts/_test_import.gd`, `scripts/*.uid`, `assets/*.import`, `assets/world/*.import`,
  `icon.png.import`.
- Mensagens de commit em português, sem identificador de modelo, terminando com:
  ```
  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01BAEqrow7UPKKJKdx55KHLH
  ```
- **Os dois importadores têm de gerar a mesma saída**: `tools/import_eu4.py` (grava em `data/eu4/`
  e `assets/eu4/`) e `scripts/eu4_importer.gd` (dentro do jogo, grava em `user://eu4/`). Toda mudança
  vai nos dois, e a saída é comparada (JSON por conteúdo, PNG pixel a pixel; os centros das
  províncias podem diferir em 0,1 por arredondamento, isso já era assim).
- Mantenha o `CLAUDE.md` atualizado a cada recurso novo (é a documentação do projeto).

## Como testar (o que funcionou nesta sessão)
- Checar erros de script: `godot --headless --editor --path . --quit-after 50`.
- Importador Python: `python3 tools/import_eu4.py "<pasta do EU4>"`.
- Importador do jogo sem interface: um script `scripts/_test_import.gd` (extends SceneTree) que
  cria `Eu4Importer`, chama `add_source(pasta)` e `run()` e imprime `error`/`status`; rodar com
  `godot --headless --path . -s res://scripts/_test_import.gd -- "<pasta do EU4>"`.
- Capturas de tela: um `scripts/_t.gd` (extends SceneTree) que instancia `main.tscn`, espera uns
  quadros, chama `main._start_game("TAG")`, mexe na câmera (`main.camera.set_height(...)`,
  `main.camera.position`) e salva `root.get_texture().get_image().save_png(...)`. Rodar com
  `godot --path . --rendering-driver opengl3 --resolution 2340x1080 -s res://scripts/_t.gd`.
- Avançar o tempo nos testes com `main.clock._advance_day()` (emitir `month_passed` à mão não muda
  a data).

## O que foi feito por último (já commitado)
Expansão agressiva e coalizões, `Eu4Data` (todos os scripts do EU4 importados), zoom do EU4
(`MapCamera`), tela de escolha de país do EU4 (`Eu4Frontend`), nomes de países e províncias no mapa
(`MapNames`), texturas do mapa (relevo `world_normal.bmp`, profundidade `heightmap.bmp`, terreno
`terrain.bmp`), fronteiras suavizadas no shader e rios em curvas (`RiverLayer`). Detalhes no
`CLAUDE.md`.

## Pedido em aberto: texturas de Terra Incógnita, névoa de guerra, água e terreno
O usuário quer o visual do EU4 usando as texturas originais. Elas **não estavam** nos arquivos que
ele mandou para a sessão na nuvem (lá só havia `gfx/interface`, `gfx/flags`, `gfx/fonts`); na
instalação dele devem estar em:
- `gfx/map/` — Terra Incógnita, névoa, água, bordas, etc.
- `gfx/FX/` — shaders do EU4 (mostram como as texturas são combinadas; leia-os para reproduzir).
- `map/terrain/` — `colormap_spring/summer/autumn/winter.dds`, `colormap_water.dds`, `atlas0.dds`,
  `atlas_normal0.dds` e afins.

Já pronto para isso:
- Os dois importadores já procuram `map/terrain/colormap_summer.dds` (ou outra estação) e
  `colormap_water.dds` e gravam `colormap.png`/`colormap_water.png`; o shader
  (`shaders/map.gdshader`) usa no modo terreno e no mar (`has_colormap`, `has_water_colormap`).
  **Nunca foi testado com os arquivos reais**: confira os nomes, o formato DDS (o leitor do jogo é
  `Eu4Importer._dds`: RGBA com máscaras e DXT1/3/5) e o resultado na tela.
- O importador do jogo só lê de `gfx/` as pastas `flags`, `interface` e `fonts`
  (`Eu4Importer._walk` e `_rel`); para usar `gfx/map` e `gfx/FX` é preciso liberar essas pastas lá
  e no Python.

Falta fazer:
1. Examinar `gfx/map`, `gfx/FX` e `map/terrain` da instalação e decidir o que importar (os dois
   importadores, mesma saída) e como o shader do mapa vai usar (seguir os shaders de `gfx/FX`).
2. **Terra Incógnita** (regras do EU4, dados já importados em `Eu4Data`):
   - O que cada país conhece vem do `discovered_by` de `history/provinces` (por grupo tecnológico —
     western, eastern, ottoman, muslim, chinese... — e por tag, inclusive datado, ex.
     `1707.5.12 = { discovered_by = GBR }`); vale o estado em 11/11/1444.
   - Constantes do `defines.lua`: `PROVINCE_DISCOVERY_YEARS_TECHNOLOGY = 50` e
     `PROVINCE_DISCOVERY_YEARS_RELIGION = 100` (descobertas se espalham pelo grupo/religião),
     `PROVINCE_DISCOVERY_PRESTIGE = 0.1`, `MAX_DISCOVERED_PROVINCE_DISTANCE = 500`,
     `MIN_SHIPS_TO_EXPLORE`, `EXPLORATION_TRAVEL_TIME`, `SEA_EXPLORE_SPEED`.
   - Dica do EU4 (localização `HINT_TERRAINCOGNITA_TEXT`): sem explorador/conquistador não se entra
     em Terra Incógnita, exceto em terra de quem está em guerra com você. O jogo ainda não tem
     generais nem frota, então exploradores/conquistadores ficam para depois.
   - Província desconhecida aparece como Terra Incógnita no mapa e não entra no caminho dos
     exércitos (`Army.find_path`/`allowed_owners`).
3. **Névoa de guerra**: no EU4 só se vê o que está perto das suas províncias, das dos aliados/súditos
   e dos seus exércitos; o resto fica sob névoa (exércitos inimigos escondidos). Única regra nos
   arquivos: `FOG_OF_WAR_FORGET_CHANCE = 1` (IA esquece unidade escondida, % por dia). Textos:
   "Fog of War", ação de espionagem `INFILTRATEDESC` (tira a névoa do alvo).
4. Água e bordas com as texturas do EU4, colormaps por estação (`map/seasons.txt`), texturas de
   detalhe do terreno (`atlas0.dds` + `terrain.bmp`).

O usuário aceitou fazer as regras de Terra Incógnita/névoa com visual provisório enquanto as
texturas não chegam, mas a escolha final ficou para quando os arquivos estiverem disponíveis.

## Outras coisas que ainda não existem (ver "Ainda NÃO existem" no CLAUDE.md)
Devolver núcleos/libertar países/anular tratados na paz, cansaço de guerra, IA que declara guerra/
constrói/desenvolve/faz diplomacia, rivais, generais, frota, estamentos, reformas de governo,
eventos/decisões/missões, salvamento, marcadores de outras datas (o mapa é importado em 1444),
posto (government rank) de quem não tem no histórico, tréguas de 1444 (ex. Hungria–Otomanos).
