# Imperium Mundi

Protótipo de grand strategy em Godot 4.x, inspirado em Europa Universalis IV.
Mapa de exemplo com **1006 províncias** (939 de terra, 67 de mar) e 24 países.

## Como abrir
1. Abra o Godot 4.3 ou mais novo, clique em **Importar** e escolha `project.godot`.
2. Aperte **F5**. Na primeira abertura o Godot importa as imagens do mapa.

## Controles
| Ação | Tecla / mouse |
|---|---|
| Selecionar província | Botão esquerdo |
| Mover câmera | WASD, setas ou arrastar com botão direito/do meio |
| Zoom | Roda do mouse |
| Pausar / continuar | Espaço |
| Velocidade | `+` e `-` (1 a 5) |

## Estrutura
- `scripts/main.gd` — câmera, interface, escolha de país e entrada.
- `scripts/map_view.gd` — carrega o mapa, gerencia a paleta e a seleção.
- `shaders/map.gdshader` — pinta o mapa e as bordas na GPU (costa e fronteiras fortes, divisas internas leves).
- `scripts/game_clock.gd` — data, pausa, velocidades e sinais de dia/mês/ano.
- `data/map.json` — províncias, países, centros e vizinhanças.
- `assets/province_ids.png` — id de cada província (R = byte baixo, G = byte alto). É o que o jogo lê.
- `assets/provinces.png` — a mesma divisão com uma cor única por província, para ver e editar.
- `tools/gen_map.py` — gera um mapa novo.

## Gerar outro mapa
```
pip install pillow numpy scipy
python3 tools/gen_map.py 35     # 35 = espaçamento; menor = mais províncias
```
Para mais de ~1000 províncias, use um valor menor (ex.: `python3 tools/gen_map.py 25`
dá cerca de 2000). Mudar `W, H` no script muda o tamanho do mapa; ajuste também o
`map_size` padrão em `shaders/map.gdshader` se quiser (o jogo já passa o tamanho certo).

## Usar seu próprio mapa
1. Desenhe `assets/provinces.png` com uma cor sólida única por província.
2. Registre cada província em `data/map.json` (`id` sequencial 0..N-1, `color`, `name`, `sea`, `owner`, `terrain`, `development`, `center`, `neighbors`).
3. Rode `python3 tools/colors_to_ids.py` para gerar `assets/province_ids.png`.

## Próximos passos
Economia (tesouro, renda mensal em `_on_month_passed`), exércitos e movimento,
declaração de guerra e cerco, diplomacia, IA, eventos e salvamento de jogo.
