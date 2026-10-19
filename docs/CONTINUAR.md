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
- Godot 4.7.2 (projeto e CI; atualizado da 4.3 a pedido do usuário em 19/10/2026). Python 3 com
  pillow, numpy, scipy para `tools/`.
- **Nunca commitar dados da Paradox**: `data/eu4/` e `assets/eu4/` estão no .gitignore. Nunca
  commitar `tools/data/raw/`.
- Antes de commitar, apague os scripts de teste (`scripts/_t*.gd`, `scripts/_test_import.gd` e os
  `.uid` deles). Os `.uid` dos scripts e shaders de verdade **vão para o git** (o Godot 4.4+ os usa
  para achar os arquivos; o `main.tscn` aponta o main.gd pelo uid); os `.import` ficam fora
  (.gitignore: o CI reimporta).
- Mensagens de commit em português, sem identificador de modelo, terminando com:
  ```
  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01BAEqrow7UPKKJKdx55KHLH
  ```
- **Os dois importadores têm de gerar a mesma saída**: `tools/import_eu4.py` (grava em `data/eu4/`
  e `assets/eu4/`) e `scripts/eu4_importer.gd` (dentro do jogo, grava em `user://eu4/`). Toda mudança
  vai nos dois, e a saída é comparada (JSON por conteúdo, PNG pixel a pixel; os centros das
  províncias podem diferir em 0,1 por arredondamento, isso já era assim; desde o Godot 4.7 as imagens
  que o Godot decodifica — DDS, TGA: ícones, bandeiras, telas, colormaps — diferem do Pillow em até
  ±1 de cor, o que é aceito).
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
Terra Incógnita e névoa de guerra com as texturas do EU4 (`Discovery`, `FogLayer`) e o mar com o
`colormap_water`. Antes: expansão agressiva e coalizões, `Eu4Data` (todos os scripts do EU4
importados), zoom do EU4 (`MapCamera`), tela de escolha de país do EU4 (`Eu4Frontend`), nomes no
mapa (`MapNames`), texturas do mapa (relevo, profundidade, terreno), fronteiras suavizadas e rios em
curvas (`RiverLayer`). Detalhes no `CLAUDE.md`.

## Sessão local (Claude Desktop, 18/10/2026): o que se aprendeu
- O projeto está em `C:\Users\vitor\Imperio--munde`. Godot 4.7.2 em `C:\Users\vitor\godot\`
  (projeto e CI também na 4.7.2).
  A placa do PC (Intel HD 4600) só roda o renderizador de compatibilidade, como o celular: use
  `Godot_v4.7.2-stable_win64_console.exe --rendering-driver opengl3` nas capturas. Python 3.14 com
  pillow/numpy/scipy (comando `python`, não `python3`).
- Na instalação do usuário **não existe `gfx/map`**: as texturas do mapa estão em `map/terrain/`
  (`map_overlay_tile.dds` = Terra Incógnita, `Fogofwar.dds` = ruído da névoa, colormaps, `atlas0.dds`,
  `water_border.dds`, `border*.dds`, `waternormal.bmp`...) e os shaders em `gfx/FX/` (`pdxmap.shader`,
  `pdxwater.shader`, `standardfuncsgfx.fxh`).
- Colormaps testados com os arquivos reais: certos (norte para cima). O mar saía **branco** porque o
  `map.gdshader` tinha 9 texturas e o renderizador de compatibilidade só aceita 8; corrigido (paleta
  do terreno na linha 5 da paleta das províncias). Ver "Limite de texturas" no CLAUDE.md.
- O usuário precisa **importar de novo** no jogo para ganhar `terra_incognita.png` e `fow_noise.png`
  (sem elas: Terra Incógnita em cor lisa e névoa sem ruído).
- Comparação dos importadores: no Godot 4.7 tudo o que o Godot decodifica (DDS, TGA, ícones,
  bandeiras) difere do Python (±1 nos DDS); o resto é idêntico.

## Pedido em aberto: o resto do visual do mapa do EU4
1. Água como no EU4: o `pdxwater.shader` é 3D (reflexo, refração do fundo, `colormap_water` a 30%);
   no 2D o jogo usa o `colormap_water` + profundidade (aproximação). Falta uma aproximação melhor
   (ondas animadas com `waternormal.bmp`, `water_border.dds` na costa).
2. Colormaps por estação (`map/seasons.txt`; hoje só o de verão) e texturas de detalhe do terreno
   (`atlas0.dds` 2048² em ladrilhos + `atlas_normal0.dds`, índice do `terrain.bmp`; ver
   `sample_terrain`/`calculate_index` no `pdxmap.shader`). Cuidado com o limite de 8 texturas.
3. Bordas do EU4 (`border0..7.dds`, `border*corner.dds`): hoje são linhas do shader.
4. Exploradores/conquistadores e frota (para entrar na Terra Incógnita), compartilhar mapas,
   alcance de visão exato e a IA respeitando a névoa (`FOG_OF_WAR_FORGET_CHANCE`).

## Outras coisas que ainda não existem (ver "Ainda NÃO existem" no CLAUDE.md)
Devolver núcleos/libertar países/anular tratados na paz, cansaço de guerra, IA que declara guerra/
constrói/desenvolve/faz diplomacia, rivais, generais, frota, estamentos, reformas de governo,
eventos/decisões/missões, salvamento, marcadores de outras datas (o mapa é importado em 1444),
posto (government rank) de quem não tem no histórico, tréguas de 1444 (ex. Hungria–Otomanos).
