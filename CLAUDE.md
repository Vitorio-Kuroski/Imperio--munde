# Imperium Mundi

Jogo de grand strategy em Godot 4.x (GDScript), inspirado em Europa Universalis IV.
Idioma do jogo e dos comentários: português do Brasil.

## Estado atual
- Mapa real (Europa + Oriente Médio + N. África), projeção Mercator, 2048x2411 px, 978 províncias (934 terra, 44 mar).
- 107 países de 1444 com capitais e cidades reais. Fronteiras APROXIMADAS (ver `tools/data/nations_1444.txt`); não são os dados do EU4.
- Escolha de país (lista ordenada por tamanho), câmera (WASD/setas/arrastar, zoom), seleção de província, relógio com pausa e 5 velocidades.
- Ainda NÃO existem: economia, exércitos, guerra, diplomacia, IA, eventos, salvamento.

## Estrutura
- `main.tscn` + `scripts/main.gd`: câmera, interface (criada em código), escolha de país, entrada.
- `scripts/map_view.gd`: carrega `data/map.json` e `assets/province_ids.png`; mantém a paleta (textura N×2) usada pelo shader.
- `shaders/map.gdshader`: pinta províncias e bordas na GPU. Linha 0 da paleta = cor; linha 1 = R índice do país dono (0 = nenhum, máx. 255 países), A = 1.0 se for mar.
- `scripts/game_clock.gd`: data, pausa, velocidade; sinais `day_passed`, `month_passed`, `year_passed`, `changed`.
- `data/map.json`: províncias (id, name, sea, owner, terrain, development, center [px], neighbors), países (tag, name, color, capital).
- `tools/gen_map.py`: gera o mapa (`python3 tools/gen_map.py [alvo_terra]`). Requer pillow, numpy, scipy.
- `tools/data/nations_1444.txt`: países e cidades-âncora (lat/lon). `tools/data/ne_50m_land.geojson`: contorno da terra (Natural Earth).
- `tools/colors_to_ids.py`: converte um `provinces.png` de cores únicas em `province_ids.png` (para mapas desenhados à mão).

## Convenções
- Dono de província muda por `MapView.set_owner_of(pid, tag)` (atualiza 2 pixels da paleta); nunca pinte pixels em loop.
- Lógica mensal (economia, eventos, IA) entra em `_on_month_passed` ou conectada a `clock.month_passed`.
- Prefira novos sistemas em scripts separados em `scripts/` (ex.: `economy.gd`, `army.gd`) em vez de crescer o `main.gd`.
- Não edite `province_ids.png`/`map.json` na mão; ajuste `nations_1444.txt` e regenere. Regenerar muda os ids das províncias.

## Como rodar
- Pelo editor: importe `project.godot` e aperte F5.
- Pela linha de comando: `godot --path .` (ou `godot --headless --path . --quit` para checar erros de script).

## Próximos passos sugeridos
1. Economia: tesouro, renda e gastos mensais por país.
2. Exércitos: unidades nas províncias, movimento pelos vizinhos.
3. Guerra: declaração, ocupação e cerco, paz com troca de províncias.
4. IA básica para os outros países, depois diplomacia e eventos.
5. Salvar e carregar jogo.
