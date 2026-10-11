# Imperium Mundi

Protótipo de grand strategy em Godot 4.x, inspirado em Europa Universalis IV.
Mapa real da **Europa, Oriente Médio e Norte da África** com **1989 províncias** (1945 de terra, 44 de mar)
e **113 países de 1444** (Otomanos, França, Castela, Polônia, Lituânia, Mamelucos, Timúridas, estados do Sacro Império etc.).

> **Aviso de fidelidade:** os países, capitais e cidades são reais, mas as fronteiras de 1444 são uma
> **aproximação** (cada província vai para o país com a cidade-âncora mais próxima). Não são os dados
> exatos do EU4. Para ajustar, edite `tools/data/nations_1444.txt` e rode o gerador.

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
- `shaders/map.gdshader` — pinta províncias e bordas na GPU (costa e fronteiras fortes, divisas internas leves).
- `scripts/game_clock.gd` — data (11 nov 1444), pausa, velocidades e sinais de dia/mês/ano.
- `data/map.json` — províncias, países, centros e vizinhanças.
- `assets/province_ids.png` — id de cada província (R = byte baixo, G = byte alto). É o que o jogo lê.
- `assets/provinces.png` — a mesma divisão com uma cor única por província, para ver e editar.
- `tools/gen_map.py` — gera o mapa a partir dos dados abaixo.
- `tools/data/nations_1444.txt` — países de 1444 e cidades-âncora (lat/lon).
- `tools/data/ne_50m_land.geojson` — contorno real da terra (Natural Earth, domínio público).

## Regenerar o mapa
```
pip install pillow numpy scipy
python3 tools/gen_map.py 1956     # ~2000 províncias no total (44 de mar)
python3 tools/gen_map.py 940      # alvo diferente (ex.: ~1000 no total) (as cidades-âncora são sempre mantidas)
```
O gerador usa as cidades do arquivo de nações como províncias nomeadas e completa o resto do mapa com
províncias extras (nomeadas pela cidade mais próxima, ex.: "Paris Norte"). Cidades isoladas ou
muito próximas de outra (< ~30 km) são descartadas.

## Editar países
Cada linha de `tools/data/nations_1444.txt`:
```
TAG|Nome|r,g,b|Capital,lat,lon;Cidade,lat,lon,alcance_km;...
```
A primeira cidade é a capital. O alcance (padrão 75 km) amplia ou reduz a área de influência da cidade.
Terra a mais de 200 km de qualquer âncora fica sem dono (Saara, Arábia, estepes).

## Próximos passos
Economia (tesouro, renda mensal em `_on_month_passed`), exércitos e movimento,
declaração de guerra e cerco, diplomacia, IA, eventos e salvamento de jogo.
