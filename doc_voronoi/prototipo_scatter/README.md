# Protótipo: interpolação nativa Voronoi via modo "scatter" do `convert_mpas`

Objetivo: validar, antes de decidir o escopo de implementação, se dá pra
interpolar direto da malha nativa MPAS (Voronoi/dual de Delaunay) para
pontos arbitrários — em vez de para uma grade lat-lon regular — reusando o
motor de interpolação que já existe dentro do `convert_mpas` (dependência
já usada pelo `selfgrib`).

## O que descobrimos lendo o código

`core/vendor/convert_mpas/README.md` já documentava que o programa faz interpolação
**baricêntrica no triângulo da malha dual de Delaunay** para campos de
célula — exatamente o método descrito em Ha et al. (2017, *MWR*,
"Ensemble Kalman Filter Data Assimilation for MPAS", o sistema
MPAS-DART do NCAR, ver `doc_voronoi/mwre-mwr-d-17-0145.1.pdf`, Eq. 6 e
Fig. 1).

O executável `convert_mpas` (linha de comando) só expõe a variante "grade
lat-lon regular" como destino (arquivo `target_domain`). Mas o módulo
`target_mesh.F90` (`target_mesh_setup`) já tem um segundo modo, não
exposto na CLI, que aceita arrays `lat2d`/`lon2d` (radianos) diretamente —
uma lista de pontos arbitrários (`irank=1`) em vez de uma grade
`nLat x nLon` (`irank=0`). O motor de pesos (`remapper.F90`,
`remap_info_setup`/`remap_field`) já é agnóstico entre os dois modos.

## O que o protótipo faz

`proto_scatter.F90` é um programa Fortran novo (não integrado ao
`convert_mpas`) que reusa os módulos já compilados do `convert_mpas`
(`mpas_mesh`, `target_mesh`, `remapper`, `scan_input`) para:

1. Ler a malha `x1.2562.static.nc` (malha de teste global, 2562 células —
   único arquivo de malha MPAS real disponível localmente; a malha regional
   real e as rodadas globais reais só existem no cluster Jaci).
2. Definir 5 pontos-alvo dispersos (não uma grade): 4 exatamente em cima de
   centros de célula reais (pra testar recuperação exata) + 1 no meio do
   caminho entre duas células vizinhas (pra testar interpolação de verdade).
3. Interpolar um campo escalar sintético e suave, `test_smooth = cos(lat)
   * sin(2*lon)`, adicionado à malha via `criar_campo_teste` (não incluído
   aqui — foi feito ad-hoc com `netCDF4`/Python durante a sessão).
4. Comparar contra o valor analítico exato e contra o resultado do
   `convert_mpas` padrão (grade lat-lon global fina, 0.25°, 720x1440 —
   round-trip malha nativa → grade → reamostragem bilinear nos mesmos 5
   pontos).

## Resultado

| pt | analítico | scatter direto (erro) | via grade 0.25° (erro) |
|---|---|---|---|
| 1 (centro de célula) | -0.535304 | -0.535304 (**0.000000**) | -0.535106 (0.000198) |
| 2 (centro de célula) | -0.292795 | -0.292795 (**0.000000**) | -0.292690 (0.000105) |
| 3 (centro de célula) | 0.266648 | 0.266648 (**0.000000**) | 0.266613 (-0.000035) |
| 4 (centro de célula) | 0.961836 | 0.961836 (**0.000000**) | 0.961528 (-0.000308) |
| 5 (meio do caminho entre 2 células) | -0.264611 | -0.264339 (0.000272) | -0.264280 (0.000331) |

**Confirmado**: a interpolação baricêntrica direta na malha nativa
(scatter) reproduz **exatamente** o valor nos centros de célula
(propriedade interpolante, C0), enquanto passar por uma grade lat-lon
intermediária — mesmo bem fina (0.25°) — introduz um erro sistemático
mensurável, mesmo nos próprios centros de célula, só pelo arredondamento
geométrico do round-trip malha→grade→reamostragem. No ponto 5 (onde os
dois métodos de fato interpolam, não só recuperam um valor nodal), o erro
é da mesma ordem de grandeza para os dois — mas na pipeline real da
produção o round-trip teria um segundo salto (grade lat-lon →
`init_atmosphere_model` reamostra de volta pra malha nativa regional), o
que dobraria essa perda.

Isso também confirma, de forma independente, a causa raiz da classe de bug
já documentada em `core/src/README.md` §6.1 (grade lat-lon menor
que a extensão real da malha): usar pontos dispersos elimina esse bug por
construção — não existe mais "grade" para a malha regional exceder.

## Como rodar de novo

Precisa do `convert_mpas` já compilado (`make FC=gfortran` — ver
`core/vendor/convert_mpas/README.md` e `core/src/README.md` §1.3 sobre
`nf-config` apontando pra um compilador inexistente neste ambiente).

```bash
FC=gfortran
FCINCLUDES=$(nf-config --fflags)
FCLIBS="-L$(nc-config --libdir) $(nf-config --flibs)"
SRC=../../core/vendor/convert_mpas/src
$FC -O2 -I"$SRC" $FCINCLUDES -o proto_scatter proto_scatter.F90 \
    "$SRC/mpas_mesh.o" "$SRC/target_mesh.o" "$SRC/remapper.o" "$SRC/scan_input.o" \
    $FCLIBS
LD_LIBRARY_PATH=$(nc-config --libdir):$LD_LIBRARY_PATH ./proto_scatter
```

Requer um `test_mesh.nc` com a variável `test_smooth(Time, nCells)`
adicionada (não versionado aqui, é gerado ad-hoc a partir de qualquer
`*.static.nc` real).

## Decisão tomada e implementada

Das duas linhas de escopo cogitadas neste protótipo, foi escolhida e
implementada por inteiro a opção **"Completa"**: pular o formato
WPS/`config_init_case` inteiramente e escrever `init.nc`/`lbc.*.nc`
diretamente (interpolação horizontal nativa + grade vertical + balanço
hidrostático + campos de superfície, tudo reimplementado a partir do
código-fonte real do MPAS-Model) — pipeline "de verdade" ao estilo
MPAS-DART/JEDI.

Esse protótipo (`proto_scatter.F90`) foi o que validou, num caso mínimo e
controlado, que a interpolação baricêntrica escalar no triângulo dual de
Delaunay é exata nos centros de célula antes de investir na implementação
completa. O resultado — pipeline com 7 fases, `init.nc`/`lbc.*.nc`
validados numericamente e uma previsão de 24h rodando de ponta a ponta no
`mpas_atmosphere` real — está em `core/src/README.md` §2.4,
`core/pipeline/native/README.md` (orquestração) e no relatório técnico
completo em `doc_voronoi/relatorio_tecnico/` (local, fora do git).
