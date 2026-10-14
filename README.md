# Imperium Mundi

Protótipo de grand strategy em Godot 4.x, inspirado em Europa Universalis IV.
**Mapa-múndi** com **5270 províncias** (4535 de terra, 735 zonas marítimas), dividido a partir de uma imagem de províncias
(estilo mapchart.net, 6000x3150 px), e **232 países de 1444** (Europa, Oriente Médio, África, Ásia e Américas).

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
| Modo de mapa (político → terreno → cultura → religião* → produtos* → comércio* → regiões* → instituições* → diplomacia*) | `T` ou botão na barra superior |
| Ver província, cultura, religião, produto, nó de comércio, área, dono ou terreno | Passar o mouse sobre o mapa |

\* Os modos religião, produtos, comércio, regiões, instituições e diplomacia só aparecem com o mapa importado do EU4.

## Estrutura
- `scripts/main.gd` — câmera, interface, escolha de país e entrada.
- `scripts/map_view.gd` — carrega o mapa, gerencia a paleta e a seleção.
- `shaders/map.gdshader` — pinta províncias e bordas na GPU (costa e fronteiras fortes, divisas internas leves).
- `scripts/game_clock.gd` — data (11 nov 1444), pausa, velocidades e sinais de dia/mês/ano.
- `data/map.json` — províncias, países, centros e vizinhanças.
- `assets/province_ids.png` — id de cada província (R = byte baixo, G = byte alto). É o que o jogo lê.
- `assets/provinces.png` — a mesma divisão com uma cor única por província, para ver e editar.
- `tools/import_eu4.py` — importa mapa e donos de 1444 da sua instalação do EU4 (dados exatos).
- `tools/gen_map.py` — gera o mapa de exemplo a partir dos dados abaixo.
- `tools/data/nations_1444.txt` — países de 1444 e cidades-âncora (lat/lon).
- `tools/data/ne_50m_land.geojson` — contorno real da terra (Natural Earth, domínio público).

## Fronteiras exatas de 1444 (importar do seu EU4)
O mapa de exemplo é aproximado. Se você tem o **Europa Universalis IV**, dá para usar o mapa,
as províncias e os donos de 1444 dele.

**Dentro do jogo (PC ou celular):** na tela de escolha de país, toque em **Pasta do EU4...** e escolha
a pasta do jogo (ex.: `...\steamapps\common\Europa Universalis IV`) ou em **Arquivos .zip...** e
escolha um ou mais .zip com `map/`, `history/` e `common/` do jogo (pode ser um `provinces.zip` só com
o `provinces.bmp`). A importação leva alguns segundos (mais no celular) e grava o resultado em
`user://eu4/` (pasta de dados do jogo, fora do projeto); o jogo recarrega já com o mapa do EU4.
**Mapa padrão** apaga a importação e volta ao mapa do jogo. No Android o jogo pede acesso aos arquivos.

**Pelo script (para desenvolver no editor):**
```
pip install pillow numpy
python3 tools/import_eu4.py                                    # tenta achar o jogo sozinho
python3 tools/import_eu4.py "C:\\Program Files (x86)\\Steam\\steamapps\\common\\Europa Universalis IV"
```
O script lê `map/` (provinces.bmp, definition.csv, default.map, e se houver climate.txt e heightmap.bmp), `history/provinces` e `history/countries` (obrigatórios) e, se houver, `common/` e `localisation/` do jogo. Ele gera
`data/eu4/map.json` + `assets/eu4/province_ids.png` (~5000 províncias, mundo todo, ~190 países).
O Godot passa a usar essa pasta automaticamente (o mapa importado dentro do jogo, em `user://eu4/`, tem prioridade sobre ela); para voltar ao mapa de exemplo, apague `data/eu4` e `assets/eu4`.
- Esses arquivos são derivados de dados da Paradox: já estão no `.gitignore`. **Não publique no GitHub nem distribua.**
- Com a pasta `gfx/flags/` (ou um .zip da pasta `gfx` com `flags/TAG.tga`) vêm as bandeiras dos países: aparecem na lista de escolha de país, na barra superior, no painel do país e na dica do mapa (modos político e diplomacia).
- Com a pasta `gfx/interface/` e os arquivos `interface/*.gfx` (ou um .zip da pasta `gfx` + o da pasta `interface`) vêm os ícones: produtos, religiões, instituições, conselheiros (retratos), construções, grupos de ideias e ideias. Aparecem na dica do mapa, nos painéis da província e do país e nas janelas de ideias e conselheiros. Só uns 400 ícones são lidos, e o atlas gerado (`icons.png`) fica fora do projeto como o resto da importação.
- Dos mesmos arquivos vem o visual do EU4: moldura dourada das janelas e painéis, botões, abas e barra de rolagem.
- Com `interface/*.gui` e `gfx/fonts/` (os .zip das pastas `interface` e `gfx`), o jogo monta as próprias telas do EU4: a barra superior com o escudo e a bandeira, a data e a velocidade com o banner "Pausado" e os botões dos modos de mapa, com as fontes do EU4. Ao clicar numa província de terra abre a tela da província do EU4 (desenvolvimento, renda, religião, cultura, terreno, produto, nó de comércio, construções). O escudo da barra superior (ou a faixa do nome na tela da província) abre a tela do país do EU4: Corte (governante, herdeiro, conselheiros, foco nacional) e Governo (governo, reformas, culturas), Economia (receitas, despesas e saldo como no EU4), Tecnologia (as três árvores, pesquisa e efeitos acumulados) e Ideias (nacionais e grupos, compra da próxima ideia), além de um resumo em texto.
- Com a pasta `localisation/` (ex.: um .zip da pasta do jogo inteira com `map/`, `history/`, `common/` e `localisation/`), os nomes oficiais em inglês aparecem onde não há tradução: províncias, países, culturas, áreas, ideias, unidades e tecnologias militares. Sem ela, os nomes são gerados a partir dos ids.
- Nomes de países e províncias vêm da localização em inglês; o terreno vem do heightmap e do clima do jogo, e a cultura e a religião de cada província também são importadas. As religiões (cores e grupos) vêm de `common/religions`; os nomes ficam em português (`data/religioes_pt.json`) e aparecem no **modo de mapa religião**. Também vêm o produto de cada província (`common/tradegoods` e `common/prices`: cor e preço base; nomes em `data/produtos_pt.json`, **modo de mapa produtos**) e o desenvolvimento separado em imposto, produção e efetivo (mostrado no painel da província). Os 80 nós de comércio (`common/tradenodes`) formam o **modo de mapa comércio**, com setas mostrando para onde o comércio corre e um círculo na sede de cada nó; as construções (`common/buildings`: custo, tempo e efeitos) e as que já existem em 1444 (fortes, estaleiros) e o nível de centro de comércio aparecem no painel da província. Com a pasta `map/` completa (`terrain.txt`, `terrain.bmp`, `trees.bmp`, `rivers.bmp`, `area.txt`, `region.txt`, `superregion.txt`, `continent.txt`, `adjacencies.csv`) vêm também o terreno exato do EU4 (com custo de movimento, defesa e limite de suprimento), os rios desenhados no mapa, áreas/regiões/super-regiões/continentes (**modo de mapa regiões**) e os estreitos. Do `history/countries` + `common/governments` vem o **painel do país** (canto superior direito, mostra o dono da província clicada): governo e reformas, posto, capital, grupo tecnológico, cultura principal e aceitas, religião, foco nacional, governante e herdeiro com idade e adm/dip/mil, e o nível de tecnologia. O botão **Ver tecnologias** mostra as três árvores (administrativa, diplomática e militar; `common/technologies`) com ano, efeitos, construções/governos/unidades liberados e instituições esperadas, e a aba **Unidades** (`common/units`): as unidades do grupo tecnológico do país, artilharia e navios, com fogo/choque/moral/manobra ou casco/canhões/marinheiros/velocidade; o painel do país mostra o exército atual (melhor infantaria, cavalaria e artilharia já liberadas). **Pontos de monarca:** todo mês cada país ganha 3 + a nota do governante em adm, dip e mil (começa com 50, máximo 999; aparecem na barra superior e no painel do país). Eles pagam o próximo nível de cada árvore: 600 pontos × (1 + custo do grupo tecnológico), +10% por ano antes do ano da tecnologia. Você pesquisa pelo botão **Pesquisar** em cada aba da janela de tecnologias; os outros países pesquisam sozinhos. **Ideias** (`common/ideas`; botão **Ver ideias** no painel do país): cada país tem suas ideias nacionais (tradições, 7 ideias e ambição; ou as do seu grupo cultural/genéricas), e os 25 grupos de ideias (Administração, Comércio, Qualidade…) podem ser adotados quando houver vaga (a 1ª vem com a tecnologia administrativa 5, em 1466). Cada ideia custa 400 pontos da categoria do grupo; a cada 3 ideias de grupo, libera-se 1 ideia nacional. Os efeitos aparecem em português; por enquanto só os de custo de tecnologia e de ideias valem no jogo. **Tesouro e conselheiros:** cada país tem um tesouro em ducados (renda mensal de imposto e de produção, que as ideias e conselheiros aumentam). No botão **Ver conselheiros** você contrata um conselheiro por categoria (`common/advisortypes`; ★ = histórico de `history/advisors`, como Charles d'Orléans na França de 1444): ele soma o nível (1 a 3) aos pontos de monarca do mês e dá o seu efeito, e cobra nível² ducados por mês. **Instituições** (`common/institutions`): em 1444 o Feudalismo já está em boa parte da Eurásia; as outras surgem na data e no lugar históricos (Renascimento em 1450, em Florença) e se espalham de província em província (**modo de mapa instituições**). O país adota uma instituição pelo painel do país pagando ducados (precisa estar em 10% do seu desenvolvimento); cada instituição esperada por uma tecnologia e não adotada encarece a pesquisa (Feudalismo 50% → +50%). **Diplomacia** (`history/diplomacy`): as relações de 11/11/1444 — súditos (vassalos, uniões pessoais, marcas, apanágios), alianças, casamentos reais e garantias — aparecem no painel do país e no **modo de mapa diplomacia**, colorido em relação ao país mostrado no painel (verde-escuro = ele, verde-claro = súditos, azul = aliados, rosa = casamentos, laranja = suserano); o Sacro Império (membros em cinza dourado, imperador Habsburgo e eleitores) e o imperador celestial (Ming) também aparecem. De `history/wars` vêm as guerras dos últimos 10 anos (em 11/11/1444 nenhuma guerra está ativa no EU4: a Cruzada de Varna acaba nesse dia), com as batalhas: no painel do país ("Guerra recente: Crusade of Varna… — batalha de Varna, vitória"), no painel da província onde houve batalha e no modo diplomacia (inimigos recentes em vermelho-escuro; guerra ativa em vermelho).
- Testado só com uma árvore de arquivos de exemplo no formato do EU4; se algo não bater na sua versão do jogo, me diga a mensagem de erro.

## Dono de cada província (`tools/data/donos_1444.csv`)
Cada província de terra tem o dono de 1444 definido numa linha da tabela, agrupada por país:
```
# BYZ — Império Bizantino
3456;BYZ;Istanbul
```
Para mudar um dono, troque a tag (veja as tags em `tools/data/nations_*.txt`; tag vazia = sem dono) e rode
`python3 tools/refine_world.py`. A tabela tem prioridade sobre as cidades-âncora, e o script a regrava
com os nomes atualizados. `--gerar-donos` recria a tabela a partir das âncoras (isso perde as edições).
`rebuild_europe.py` migra a tabela para os ids novos pela sobreposição das províncias.

## Refinar o mapa-múndi (sem mudar os ids)
```
pip install pillow numpy scipy
python3 tools/refine_world.py                       # donos de 1444, costa e nomes
python3 tools/refine_world.py --terreno             # também recalcula o terreno (baixa ~60 MB na 1ª vez)
python3 tools/refine_world.py --previa previa.png [--modo terreno|cultura]
```
Trabalha direto sobre `data/world/map.json` e `assets/world/province_ids.png`, então funciona sem a imagem original.
- **Donos:** cada cidade-âncora cresce pelas províncias vizinhas; os países ficam contíguos e só cruzam o mar
  quando a âncora está do outro lado. A capital é a província da maior cidade real perto da âncora.
- **Terreno:** 12 tipos (planície, floresta, colinas, montanhas, planalto, deserto, estepe, savana, selva,
  pântano, tundra, geleira) a partir do relevo (ETOPO5, NOAA) e do clima (WorldClim 2.1, Fick & Hijmans 2017).
  Os dados brutos ficam em `tools/data/raw/` (fora do git; o WorldClim não pode ser redistribuído).
  O desenvolvimento passa a ser ajustado pelo terreno (o valor original fica em `base_development`).
- **Culturas de 1444:** ~360 culturas em ~50 grupos (`tools/data/cultures_1444.txt`, aproximação histórica,
  não são os dados do EU4). Cada cultura tem cidades-âncora; toda província de terra recebe a cultura da
  âncora mais próxima alcançável pelos vizinhos. A cor vem do grupo, variando por cultura.
  Para ajustar, edite o arquivo (formato no cabeçalho) e rode `refine_world.py`.
- **Nomes:** cidades de litoral que caíam no mar voltam para a província certa (ex.: Lisboa); províncias
  remotas recebem o nome da região geográfica (`tools/data/ne_50m_geography_regions.geojson`, Natural Earth);
  em nomes repetidos a cidade mais populosa fica sem numeral (London × London de Ontário).
- Depois de editar `tools/data/nations_*.txt` ou `cultures_1444.txt`, rode `refine_world.py` (não precisa do `--terreno`).

## Redesenhar as províncias da Europa
```
pip install pillow numpy scipy scikit-image
python3 tools/rebuild_europe.py [--previa previa.png]
python3 tools/refine_world.py --terreno
```
Redesenha as províncias de terra da Europa, Anatólia e Cáucaso com dados livres (Natural Earth e ETOPO5,
baixados em `tools/data/raw/`). As sementes são cidades reais, mais densas no Sacro Império e mais
esparsas no leste e no norte. As divisas seguem cristas de montanha, rios principais e fronteiras
administrativas, com um micro-relevo para ficarem sinuosas. O resto do mundo e os mares mantêm o
formato, mas **todos os ids são renumerados**.

## Regenerar o mapa-múndi
```
pip install pillow numpy scipy
python3 tools/gen_world.py caminho/da/imagem.png preview.png
```
A imagem original não está no repositório. Regenerar muda os ids; rode `tools/refine_world.py --terreno` depois. O mapa antigo só da Europa (`tools/gen_map.py`) continua em `data/map.json`.

## Regenerar o mapa antigo da Europa
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
