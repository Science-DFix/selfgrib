# selfgrib — rota de interpolação nativa Voronoi-to-Voronoi

> *self* + *GRIB* — porque o MPAS-A vira sua própria fonte de dados, sem
> precisar de nenhum GRIB externo (GFS, BAM, Eta...). A rota nativa vai
> um passo além: em vez de passar por uma grade lat-lon intermediária e
> pelo formato binário do WPS, interpola **diretamente entre a malha de
> Voronoi nativa de origem e a de destino**, escrevendo
> `init.nc`/`lbc.*.nc` prontos para o `mpas_atmosphere`.

Esta branch (`chore/reorganiza-estrutura-core`) é a continuação direta de
`feature/interpolacao-nativa-voronoi` (onde a rota nativa foi implementada e
validada pela primeira vez): reorganiza tudo que antes vivia solto na raiz
do repositório (`scripts/`, `mpas2intermediate/`, `convert_mpas/`,
`MPAS-Limited-Area/`) dentro de uma única pasta `core/` com uma separação
clara — código próprio (`core/src`), dependências de terceiros
vendorizadas (`core/vendor`) e orquestração (`core/pipeline`) — e adiciona
um experimento real, ponta-a-ponta, em produção: uma malha global própria
de **15km** (não mais 60km), comparada lado a lado com 60km na mesma data
em [`experiments/rodada_global_15km/`](experiments/rodada_global_15km/).

## O que é isso

O ponto de partida é o **selfgrib**: um "ungrib" alternativo para o
MPAS-A que lê a saída nativa (`history.nc`) de uma rodada global do
próprio modelo e usa isso como fonte de dado meteorológico, eliminando a
dependência de GRIB externo. Essa parte está descrita em detalhe em
[`core/src/README.md`](core/src/README.md) e não é o
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

## Antes / depois: mesma rota, mesmo dia, malha de origem 60km → 15km

Comparação justa: **mesma data** (`2026-01-31_00` + 24h), **mesma região**
(`SouthAmerica`) e **mesma rota nativa**, variando só a malha global de
origem do first-guess — a rodada de produção em **60km** (`x1.163842`,
GFS como first-guess indireto) contra uma previsão global própria em
**15km** (`x1.2621442`, ~16× mais células). Detalhes completos do
experimento de 15km em
[`experiments/rodada_global_15km/README.md`](experiments/rodada_global_15km/README.md).

<table>
<tr><th width="50%">Malha de origem 60km</th><th width="50%">Malha de origem 15km</th></tr>
<tr>
<td><img src="docs/resultados_voronoi_60km_mesmodia/02_mslp_vento10m_24h.png" alt="MSLP 60km"></td>
<td><img src="docs/resultados_voronoi_15km/02_mslp_vento10m_24h.png" alt="MSLP 15km"></td>
</tr>
<tr>
<td><img src="docs/resultados_voronoi_60km_mesmodia/03_temperatura_2m_24h.png" alt="T2m 60km"></td>
<td><img src="docs/resultados_voronoi_15km/03_temperatura_2m_24h.png" alt="T2m 15km"></td>
</tr>
<tr>
<td><img src="docs/resultados_voronoi_60km_mesmodia/04_geopotencial_vento_500hPa_24h.png" alt="Z500 60km"></td>
<td><img src="docs/resultados_voronoi_15km/04_geopotencial_vento_500hPa_24h.png" alt="Z500 15km"></td>
</tr>
<tr>
<td><img src="docs/resultados_voronoi_60km_mesmodia/05_precipitacao_acumulada_24h.png" alt="Precip 60km"></td>
<td><img src="docs/resultados_voronoi_15km/05_precipitacao_acumulada_24h.png" alt="Precip 15km"></td>
</tr>
<tr>
<td><img src="docs/resultados_voronoi_60km_mesmodia/06_cape_24h.png" alt="CAPE 60km"></td>
<td><img src="docs/resultados_voronoi_15km/06_cape_24h.png" alt="CAPE 15km"></td>
</tr>
<tr>
<td><img src="docs/resultados_voronoi_60km_mesmodia/07_olr_24h.png" alt="OLR 60km"></td>
<td><img src="docs/resultados_voronoi_15km/07_olr_24h.png" alt="OLR 15km"></td>
</tr>
<tr>
<td><img src="docs/resultados_voronoi_60km_mesmodia/01_malha_nativa_zoom_cape.png" alt="Malha 60km"></td>
<td><img src="docs/resultados_voronoi_15km/01_malha_nativa_zoom_cape.png" alt="Malha 15km"></td>
</tr>
</table>

Com a mesma data, dá pra ver diferenças reais de resolução, não só de
malha: o vórtice de baixa pressão no sul fica mais definido e intenso em
15km (60km mostra um padrão mais suave/alongado na mesma região), e a
malha de Voronoi real (última linha, mesmo recorte da Amazônia central)
mostra os hexágonos ~4× menores lado a lado, célula a célula.

*Nota: o resultado de 60km acima vem da rota nativa alimentada pela
mesma rodada de produção 60km/GFS usada operacionalmente — não é o
mesmo caso de validação original (`2026-01-01`) usado na seção seguinte
para a checagem numérica campo-a-campo contra o `init.nc`/`lbc.*.nc` de
referência.*

## Validação numérica

Antes de qualquer previsão real, a rota foi validada campo a campo: o
`init.nc`/`lbc.*.nc` gerados por ela foram comparados diretamente contra os
arquivos reais de produção (mesmo caso, malha `SouthAmerica`/60km,
`2026-01-01_00`) — erro nulo ou desprezível em praticamente todos os
campos. Essa validação numérica completa (metodologia, tabelas de erro por
campo, os bugs reais encontrados no processo) está no relatório técnico
local (`doc_voronoi/relatorio_tecnico/`) e resumida em
[`core/pipeline/native/README.md`](core/pipeline/native/README.md). A
validação *funcional* — rodar o `mpas_atmosphere` de verdade a partir
desses arquivos e obter uma previsão fisicamente sã — é o que a seção
anterior mostra, agora com dois exemplos reais (60km e 15km) em vez de um.

## Documentação científica completa

A descrição completa do método — fundamentação teórica da malha de
Voronoi/dual de Delaunay, revisão da literatura, cada fase da
implementação com suas equações, os bugs reais encontrados e como
foram diagnosticados, e os resultados de validação — está em um
relatório técnico-científico em LaTeX, mantido **apenas localmente**
(fora do controle de versão, por não ser destinado a compartilhamento
público neste momento): `doc_voronoi/relatorio_tecnico/` (compile com
`make` dentro da pasta, requer `pdflatex`+`biber`).

Esse é o documento de referência para quem quiser entender o *porquê*
de cada decisão de implementação, não só o *como* — inclusive para uma
eventual apresentação/defesa do trabalho. A pasta
[`doc_voronoi/`](doc_voronoi/) também reúne os artigos de referência
usados (malhas de Voronoi, coordenada vertical *terrain-following*,
assimilação de dados no MPAS) e o protótipo inicial que validou a
abordagem (`doc_voronoi/prototipo_scatter/`).

## Estrutura do repositório

Reorganizada nesta branch — antes, `scripts/`, `mpas2intermediate/`,
`convert_mpas/` e `MPAS-Limited-Area/` viviam soltos na raiz, sem separar
código próprio de dependência vendorizada. Agora:

```
core/                     -- ferramenta unica: codigo proprio + dependencias + orquestracao
  Makefile                          -- builda vendor/ e depois src/, em ordem
  src/                               -- pipeline Fortran proprio (rota antiga via WPS + rota nova nativa)
    gen_vertical_grid.F90, gen_init_native.F90, gen_lbc_native.F90, hinterp_native.F90, ...
    README.md                        -- arquitetura completa do pipeline Fortran
  vendor/                            -- dependencias vendorizadas da NCAR, nao escritas por este projeto
    convert_mpas/                     -- motor de pesos baricentricos (usado pelas duas rotas)
    limited_area/                     -- recorte de regioes da malha global
  pipeline/                          -- orquestracao bash das duas rotas
    01_recorta_regiao.bash            -- reusado por ambas as rotas
    native/                           -- rota recomendada/validada (esta branch), ver pipeline/native/README.md
    legacy/                           -- rota antiga via WPS, mantida como referencia/comparacao
experiments/
  rodada_global_15km/                -- experimento real ponta-a-ponta: malha global propria 15km,
                                          previsao global 24h, e a rota nativa alimentada por ela
                                          (README proprio com pre-requisitos, bugs reais corrigidos
                                          rodando pela primeira vez, instrucoes de reproducao)
doc_voronoi/
  relatorio_tecnico/                -- documento científico completo (LaTeX, apenas local, fora do git)
  *.pdf                             -- artigos de referência
  prototipo_scatter/                -- protótipo inicial que validou o método
docs/
  resultados_voronoi/               -- galeria do caso de validacao original (60km, 2026-01-01)
  resultados_voronoi_60km_mesmodia/ -- mesmos 9 graficos, 60km, mesma data da rodada de 15km
  resultados_voronoi_15km/          -- global 15km x regional nativo, lado a lado
  *.pdf                             -- referências técnicas gerais do MPAS-A (manuais, notas)
```

## Compilação

```bash
cd core && make
```

(builda primeiro `vendor/convert_mpas`, depois `src/` — equivalente a
rodar os dois `make` manualmente na ordem certa.)

Isso gera, entre outros, os binários usados pela rota nativa:
`hinterp_native`, `gen_vertical_grid`, `gen_init_native`,
`gen_lbc_native` (e os da rota antiga: `extract_fields`,
`pack_intermediate`). Requer um compilador Fortran (testado com
`gfortran`) e as bibliotecas NetCDF-C/NetCDF-Fortran (`nf-config` no
`PATH`) — não precisa de MPI para compilar, os binários rodam seriais
(só o `mpas_atmosphere`/`init_atmosphere_model` originais, chamados
depois pelos scripts de orquestração, são paralelos).

Também é preciso ter o **NCO** (`ncks`) no `PATH` para rodar o passo 4
(`04_gera_init_native.bash` mescla campos estáticos com `ncks -A`) — não é
compilado por este `make`, normalmente já vem no ambiente de HPC de
geociências (`module load nco` ou equivalente).

## Como rodar (rota nativa)

Ordem de execução completa, do recorte da malha até a previsão real —
ver [`core/pipeline/native/README.md`](core/pipeline/native/README.md) para a
lista de variáveis de ambiente configuráveis e o detalhe de cada passo:

```bash
export DIR_VORONOI=/caminho/para/este/repo
export DIR_RODADA_GLOBAL=/caminho/para/uma/rodada/global/ja/concluida
export REGION_NAME=SouthAmerica   # ou outra malha ja recortada
export TIMES="2026-01-01_00 2026-01-01_06 2026-01-01_12 2026-01-01_18 2026-01-02_00"

bash core/pipeline/01_recorta_regiao.bash                    # 1. recorta a malha (reusado da rota antiga)
bash core/pipeline/native/02_extrai_first_guess.bash        # 2. extract_fields, malha global
bash core/pipeline/native/03_interp_horizontal_nativa.bash  # 3. interpolação baricêntrica malha->malha
bash core/pipeline/native/04_gera_init_native.bash          # 4. init.nc completo (grade vertical + hidrostático + superfície)
bash core/pipeline/native/05_gera_lbc_native.bash           # 5. lbc.*.nc, um por tempo de fronteira
bash core/pipeline/native/06_roda_previsao_native.bash      # 6. roda o mpas_atmosphere real a partir desses arquivos
```

Cada script é idempotente (pula o que já existe) e configurável via
variáveis de ambiente com defaults sensatos — rode sem nada exportado
para reproduzir o caso de validação (`SouthAmerica`, ~60km, 24h a
partir de `2026-01-01_00`) documentado no relatório técnico.

Isso cobre a rota em si — para um exemplo real, testado, com os scripts
`.pbs` de submissão (PBS + MPICH), a geração de uma malha global própria do
zero e a lista de bugs reais encontrados/corrigidos rodando pela primeira
vez numa resolução nova, ver
[`experiments/rodada_global_15km/README.md`](experiments/rodada_global_15km/README.md).

## A rota original (via WPS)

Ainda presente neste repositório, sem alteração de lógica (só de
localização, nesta reorganização), como referência e fallback:
[`core/pipeline/01_recorta_regiao.bash`](core/pipeline/01_recorta_regiao.bash)
mais [`core/pipeline/legacy/`](core/pipeline/legacy/) (`02_*.bash` até
`05_*.bash`), documentada em detalhe (arquitetura, bugs reais
encontrados e corrigidos, galeria de resultados) em
[`core/src/README.md`](core/src/README.md). As duas
rotas compartilham o mesmo passo de recorte de malha
(`01_recorta_regiao.bash`) e podem ser comparadas lado a lado a partir
do mesmo caso de estudo — é exatamente essa comparação que valida a
rota nativa no relatório técnico.

## Origem

Nasceu de uma pergunta simples: "dá pra gerar condição inicial do
MPAS-A usando uma rodada global do próprio MPAS-A, em vez de depender
de GRIB externo?" A resposta foi sim (rota original, via WPS). Uma
segunda pergunta, motivada por uma limitação estrutural encontrada no
caminho, levou à rota nativa: "dá pra eliminar também a grade
intermediária, interpolando direto entre as duas malhas de Voronoi?" A
resposta, depois de investigar o código-fonte real do
`init_atmosphere_model`, comparar numericamente contra arquivos de
produção reais, e finalmente rodar o `mpas_atmosphere` de verdade a
partir do resultado, também foi sim — validado na malha de referência
(`SouthAmerica`, ~60km).

Uma terceira pergunta motivou esta branch: "essa rota funciona só nessa
malha/caso específico já validado, ou generaliza de verdade?" Duas
respostas: primeiro, uma reorganização estrutural (esta branch,
`chore/reorganiza-estrutura-core`) que separa código próprio de
dependência vendorizada — pré-requisito para o repositório crescer sem
virar uma pasta única de scripts soltos. Segundo, um teste real fora do
caso de validação original: baixar e rodar uma malha global própria em
**15km** (16× mais células que 60km, nunca testada nesta rota antes) do
zero — gerar o invariant, rodar a previsão global de 24h, e alimentar a
mesma rota nativa com ela — encontrando e corrigindo, no processo, bugs
reais que só apareceriam numa malha maior (limite de tamanho do NetCDF
clássico, colisão de variável de ambiente entre passos, e outros
documentados em [`experiments/rodada_global_15km/README.md`](experiments/rodada_global_15km/README.md)).
A resposta: sim, generaliza — mesma estrutura sinótica reproduzida em
duas resoluções de origem diferentes, comparável lado a lado no topo
deste README.
