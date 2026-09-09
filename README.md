# selfgrib — rota de interpolação nativa Voronoi-to-Voronoi

> *self* + *GRIB* — porque o MPAS-A vira sua própria fonte de dados, sem
> precisar de nenhum GRIB externo (GFS, BAM, Eta...). Esta branch
> (`feature/interpolacao-nativa-voronoi`) vai um passo além: em vez de
> passar por uma grade lat-lon intermediária e pelo formato binário do
> WPS, interpola **diretamente entre a malha de Voronoi nativa de
> origem e a de destino**, escrevendo `init.nc`/`lbc.*.nc` prontos para
> o `mpas_atmosphere`.

## O que é isso

O ponto de partida é o **selfgrib**: um "ungrib" alternativo para o
MPAS-A que lê a saída nativa (`history.nc`) de uma rodada global do
próprio modelo e usa isso como fonte de dado meteorológico, eliminando a
dependência de GRIB externo. Essa parte está descrita em detalhe em
[`mpas2intermediate/README.md`](mpas2intermediate/README.md) e não é o
foco deste README — vale a pena ler se você quer entender a motivação
original do projeto, mas a rota que ele descreve (via formato WPS e
grade lat-lon) **não é o que esta branch usa por padrão**.

Esta branch resolve uma limitação estrutural daquela rota: o
`init_atmosphere_model` original só aceita, como entrada, uma grade
latitude-longitude regular — nunca uma lista de pontos dispersos. Isso
significa que, por mais fina que seja a grade intermediária, o caminho
`malha nativa → grade → malha nativa` sempre introduz um erro de
interpolação de ida-e-volta, e uma classe real de bug já documentada
(grade menor que a extensão real da malha regional, deixando células
sem dado válido na fronteira).

A rota implementada aqui interpola **diretamente entre as duas malhas
de Voronoi** — a global de origem e a regional de destino — usando o
mesmo método (interpolação baricêntrica na malha dual de Delaunay) já
validado pela comunidade MPAS via o sistema de assimilação MPAS-DART
(Ha et al., 2017, *MWR*), e reimplementa em Fortran, extraído
literalmente do código-fonte de referência do MPAS-Model, tudo que o
`init_atmosphere_model` faria a seguir — grade vertical, interpolação
vertical, balanço hidrostático, campos de superfície — escrevendo
`init.nc`/`lbc.*.nc` diretamente, sem grade intermediária e sem
depender do `init_atmosphere_model` original para gerá-los.

**Status**: validado em duas camadas — numericamente, campo a campo,
contra arquivos reais de produção; e funcionalmente, executando o
`mpas_atmosphere` real a partir dos arquivos gerados por esta rota e
obtendo uma previsão de 24h fisicamente sã, sem erros.

## Documentação científica completa

A descrição completa do método — fundamentação teórica da malha de
Voronoi/dual de Delaunay, revisão da literatura, cada fase da
implementação com suas equações, os bugs reais encontrados e como
foram diagnosticados, e os resultados de validação — está em um
relatório técnico-científico em LaTeX:

📄 **[`doc_voronoi/relatorio_tecnico/`](doc_voronoi/relatorio_tecnico/)**
(compile com `make` dentro da pasta, requer `pdflatex`+`biber`; ou leia
o `.pdf` já gerado, se presente).

Esse é o documento de referência para quem quiser entender o *porquê*
de cada decisão de implementação, não só o *como* — inclusive para uma
eventual apresentação/defesa do trabalho. A pasta
[`doc_voronoi/`](doc_voronoi/) também reúne os artigos de referência
usados (malhas de Voronoi, coordenada vertical *terrain-following*,
assimilação de dados no MPAS) e o protótipo inicial que validou a
abordagem (`doc_voronoi/prototipo_scatter/`).

## Estrutura do repositório

```
mpas2intermediate/      -- pipeline Fortran (rota antiga via WPS + rota nova nativa)
  src/gen_vertical_grid.F90, gen_init_native.F90, gen_lbc_native.F90, hinterp_native.F90, ...
convert_mpas/            -- ferramenta da NCAR, dependência (motor de pesos baricêntricos)
MPAS-Limited-Area/       -- ferramenta da NCAR para recortar regiões da malha global
scripts/
  01_recorta_regiao.bash            -- reusado por ambas as rotas
  02_*.bash .. 05_*.bash             -- rota antiga (via WPS), ver mpas2intermediate/README.md
  voronoi/                          -- rota nova (esta branch), ver scripts/voronoi/README.md
doc_voronoi/
  relatorio_tecnico/                -- o documento científico completo (LaTeX)
  *.pdf                             -- artigos de referência
  prototipo_scatter/                -- protótipo inicial que validou o método
docs/                    -- referências técnicas gerais do MPAS-A (manuais, notas)
```

## Compilação

```bash
cd convert_mpas && make FC=gfortran && cd ..
cd mpas2intermediate && make && cd ..
```

Isso gera, entre outros, os binários usados pela rota nativa:
`hinterp_native`, `gen_vertical_grid`, `gen_init_native`,
`gen_lbc_native` (e os da rota antiga: `extract_fields`,
`pack_intermediate`). Requer um compilador Fortran (testado com
`gfortran`) e as bibliotecas NetCDF-C/NetCDF-Fortran (`nf-config` no
`PATH`).

## Como rodar (rota nativa)

Ordem de execução completa, do recorte da malha até a previsão real —
ver [`scripts/voronoi/README.md`](scripts/voronoi/README.md) para a
lista de variáveis de ambiente configuráveis e o detalhe de cada passo:

```bash
export DIR_VORONOI=/caminho/para/este/repo
export DIR_RODADA_GLOBAL=/caminho/para/uma/rodada/global/ja/concluida
export REGION_NAME=SouthAmerica   # ou outra malha ja recortada
export TIMES="2026-01-01_00 2026-01-01_06 2026-01-01_12 2026-01-01_18 2026-01-02_00"

bash scripts/01_recorta_regiao.bash                    # 1. recorta a malha (reusado da rota antiga)
bash scripts/voronoi/02_extrai_first_guess.bash        # 2. extract_fields, malha global
bash scripts/voronoi/03_interp_horizontal_nativa.bash  # 3. interpolação baricêntrica malha->malha
bash scripts/voronoi/04_gera_init_native.bash          # 4. init.nc completo (grade vertical + hidrostático + superfície)
bash scripts/voronoi/05_gera_lbc_native.bash           # 5. lbc.*.nc, um por tempo de fronteira
bash scripts/voronoi/06_roda_previsao_native.bash      # 6. roda o mpas_atmosphere real a partir desses arquivos
```

Cada script é idempotente (pula o que já existe) e configurável via
variáveis de ambiente com defaults sensatos — rode sem nada exportado
para reproduzir o caso de validação (`SouthAmerica`, ~60km, 24h a
partir de `2026-01-01_00`) documentado no relatório técnico.

## A rota original (via WPS)

Ainda presente neste repositório, sem alteração, como referência e
fallback: [`scripts/01_recorta_regiao.bash`](scripts/01_recorta_regiao.bash)
até [`scripts/05_roda_previsao.bash`](scripts/05_roda_previsao.bash),
documentada em detalhe (arquitetura, bugs reais encontrados e
corrigidos, galeria de resultados) em
[`mpas2intermediate/README.md`](mpas2intermediate/README.md). As duas
rotas compartilham o mesmo passo de recorte de malha
(`01_recorta_regiao.bash`) e podem ser comparadas lado a lado a partir
do mesmo caso de estudo — é exatamente essa comparação que valida a
rota nativa no relatório técnico.

## Origem

Nasceu de uma pergunta simples: "dá pra gerar condição inicial do
MPAS-A usando uma rodada global do próprio MPAS-A, em vez de depender
de GRIB externo?" A resposta foi sim (rota original, via WPS). Uma
segunda pergunta, motivada por uma limitação estrutural encontrada no
caminho, levou a esta branch: "dá pra eliminar também a grade
intermediária, interpolando direto entre as duas malhas de Voronoi?" A
resposta, depois de investigar o código-fonte real do
`init_atmosphere_model`, comparar numericamente contra arquivos de
produção reais, e finalmente rodar o `mpas_atmosphere` de verdade a
partir do resultado, também foi sim.
