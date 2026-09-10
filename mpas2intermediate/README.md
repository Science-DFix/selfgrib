# mpas2intermediate — "pseudo-ungrib" MPAS-A global → MPAS-A regional/global

Ferramenta que substitui o `ungrib` do WPS quando a fonte de dados
meteorológicos é uma **rodada global do próprio MPAS-A** (em vez de
GRIB de GFS/BAM/ETA/etc.). Produz arquivos no formato binário
intermediário padrão do WPS, que o `init_atmosphere_model` já sabe ler
nativamente (`config_init_case=7` para condição inicial, `=9` para
fronteira lateral) — **sem nenhum patch no código-fonte do MPAS-Model**.

---

## 1. Compilação

### Dependências

- `gfortran` (testado com a versão do sistema, sem flags exóticas)
- NetCDF-Fortran (`nf-config` precisa estar no `PATH`)
- `convert_mpas` (em `../convert_mpas/`) — compilar antes, ver seção 1.2

### 1.1. Compilar esta ferramenta

```bash
cd mpas2intermediate
make
```

Gera três executáveis: `extract_fields`, `pack_intermediate` e
`test_interp` (este último só para validação/depuração da interpolação
vertical, não faz parte do fluxo de produção).

**Detalhe importante do `Makefile`:** as flags
`-fconvert=big-endian -frecord-marker=4` são obrigatórias. É a mesma
convenção usada para compilar o WPS/`ungrib` e o `MPAS-Model`
(`WPS/configure.wps`) — sem elas, o arquivo binário gerado é
lido com os bytes trocados pelo `init_atmosphere_model` (erro observado
durante o desenvolvimento: "Found version 83886080 but expected 3, 4 or 5").

### 1.2. Compilar o `convert_mpas` (dependência)

```bash
cd ../convert_mpas
make FC=gfortran
```

(`FC=gfortran` é necessário porque o `Makefile` do `convert_mpas` usa
`nf-config --fc` por padrão, que pode apontar para um compilador que não
existe neste ambiente.)

### 1.3. Troubleshooting: `cannot find -lnetcdf` ao linkar

**Sintoma:** `nf-config` funciona (`nf-config --version`, `--fflags` retornam
normalmente), a compilação (`-c`) de todos os `.F90` passa, mas o `make`
falha na etapa de link com algo como:

```
/usr/bin/ld: cannot find -lnetcdf: No such file or directory
collect2: error: ld returned 1 exit status
```

**Causa:** em ambientes que instalam dependências via Spack/EasyBuild
(comum em clusters HPC), `netcdf-c` e `netcdf-fortran` costumam ser pacotes
**separados**, cada um com seu próprio diretório de instalação. O
`nf-config --flibs` (usado pelo `Makefile` deste projeto e do
`convert_mpas`) só garante o `-L` do diretório do `netcdf-fortran` — a flag
`-lnetcdf` (a lib C, da qual o `netcdf-fortran` depende) fica sem um `-L`
correspondente, porque `nf-config` não sabe onde o `netcdf-c` foi instalado.

**Diagnóstico (genérico, qualquer Unix):**

```bash
# 1) confirmar que é exatamente essa a falta: -lnetcdf sem -L correspondente
nf-config --flibs

# 2) achar onde a libnetcdf.* realmente está instalada no sistema
#    (a) se houver nc-config (do pacote netcdf-c) no PATH, é o caminho mais direto:
nc-config --libdir 2>/dev/null

#    (b) via modules (Environment Modules/Lmod), se o cluster usar module load:
module show netcdf-c 2>&1 | grep -i -E "lib|LD_LIBRARY_PATH"

#    (c) busca direta no filesystem (ajuste </raiz/de/busca> para algo
#        razoável, ex.: /opt, /usr, /lustre/.../opt — evite buscar a partir
#        de "/" em sistemas grandes):
find </raiz/de/busca> -name "libnetcdf.so*" -o -name "libnetcdf.a" 2>/dev/null
```

**Correção:** depois de achar o diretório (`<dir_libnetcdf-c>`, o que contém
o `libnetcdf.so*`/`libnetcdf.a`), exportar `LIBRARY_PATH` antes de compilar
— é a variável que o `gcc`/`gfortran` usa para procurar `-L` adicionais na
hora de linkar, sem precisar editar o `Makefile`:

```bash
export LIBRARY_PATH=<dir_libnetcdf-c>:$LIBRARY_PATH
make clean
make
```

**Depois de compilar, confirme que o binário também *roda*:** o link em
tempo de compilação usa `LIBRARY_PATH`, mas em tempo de execução o loader
(`ld.so`) resolve as bibliotecas dinâmicas via `LD_LIBRARY_PATH` (ou cache
do `ldconfig`) — são mecanismos independentes, então um `make` bem-sucedido
não garante que o executável vai achar a lib ao rodar:

```bash
ldd extract_fields | grep -i netcdf
```

Se aparecer `=> not found`, adicione o mesmo diretório (ou o diretório onde
está a `.so` de runtime, que pode ser diferente do usado para linkar, desde
que o `soname` — ex. `libnetcdf.so.19` — seja compatível) também ao
`LD_LIBRARY_PATH`:

```bash
export LD_LIBRARY_PATH=<dir_libnetcdf-c>:$LD_LIBRARY_PATH
```

Em ambientes com `module load`, isso normalmente já é resolvido
automaticamente pelo próprio módulo do `netcdf-c` (que costuma exportar
`LD_LIBRARY_PATH`, mesmo sem exportar `LIBRARY_PATH` — por isso o problema
só aparece no link, não na execução).

---

## 2. Como rodar

### 2.1. Um único tempo (depuração / entendimento do fluxo)

```bash
# 1) extrai e interpola verticalmente (malha nativa do MPAS)
./extract_fields  /caminho/history.2026-01-02_00.00.00.nc  extracted.nc

# 2) remapeia horizontalmente para lat-lon (malha nativa -> grade regular)
#    precisa de um arquivo 'target_domain' no diretorio de trabalho (ver
#    convert_mpas/README.md) definindo a grade de destino
cd /dir/de/trabalho/com/target_domain
/caminho/para/convert_mpas  /caminho/history.2026-01-02_00.00.00.nc  extracted.nc
# gera latlon.nc

# 3) escreve o formato binario final
/caminho/para/pack_intermediate  latlon.nc  "2026-01-02_00:00:00"  MPAS
# gera MPAS:2026-01-02_00
```

### 2.2. Um ciclo inteiro (produção)

```bash
./run_pipeline.sh <dir_com_history.*.nc> <dir_saida> <prefixo> \
                   <startlat> <endlat> <startlon> <endlon> [nlat] [nlon]

# exemplo real (America do Sul, testado nesta sessao):
./run_pipeline.sh /mnt/dados2/dataout/PREV_MPAS/2025122800 \
                   /tmp/pipeline_out MPAS -60.0 25.0 -90.0 -30.0 170 240
```

O script processa **todos** os `history.*.nc` do diretório de origem, um
por tempo de previsão, gerando um `<prefixo>:AAAA-MM-DD_HH` por tempo. É
**idempotente** (pula tempos cujo arquivo final já existe) e limpa os
intermediários grandes (`extracted_*.nc`, `latlon_*.nc`) de cada tempo ao
final, mantendo só o binário final e os logs.

**Importante sobre a grade lat-lon (`startlat/endlat/startlon/endlon`):**
dê uma margem de alguns graus além da malha de simulação real. O
`convert_mpas` deixa pontos sem dado (`_FillValue`) nas poucas
colunas/linhas mais externas da grade de destino (limitação documentada no
próprio `convert_mpas/README.md`, seção de to-do sobre a busca do triângulo
de interpolação) — com margem suficiente, essas falhas de borda ficam fora
da área que a malha de simulação realmente usa.

### 2.3. Arquivo de entrada padrão

**`history.AAAA-MM-DD_HH.00.00.nc`** — e só ele. Testamos usar
`mpasout.*.nc` (saída a cada 3h, em vez de 6h do `history.nc`) mas ele não
tem `pressure` nem `zgrid` prontos (só `pressure_p+pressure_base`, e
`zgrid` nem existe nesse stream) — decidimos **não** adicionar lógica
condicional no Fortran para reconstruir esses campos a partir de outro
arquivo: se o arquivo não tem os campos prontos, não é a fonte certa para
esta ferramenta. `history.nc` sempre tem tudo pronto porque o MPAS grava a
malha completa e todos os campos de estado físico em todo `output` stream
por padrão.

### 2.4. Interpolação nativa Voronoi — `init.nc`/`lbc.*.nc` direto, sem WPS

Branch `feature/interpolacao-nativa-voronoi`: uma rota alternativa que
pula o formato binário WPS e o `init_atmosphere_model` inteiramente para
a etapa de horizontal/vertical/hidrostático, escrevendo
`init.nc`/`lbc.*.nc` diretamente. Elimina por construção a classe de bug de
"grade menor que a extensão real da malha" (§6.1) e o erro de round-trip
que uma grade lat-lon intermediária introduz mesmo bem dimensionada.
Método: interpolação baricêntrica na malha dual de Delaunay (mesma técnica
do MPAS-DART, Ha et al. 2017 MWR) + extração literal das rotinas reais do
MPAS-Model (fonte de produção, mpas-bundle 3.0.2) para grade
vertical/interpolação/balanço hidrostático/campos de superfície.

📄 **Documentação técnico-científica completa** (fundamentação teórica,
equações de cada fase, achados/bugs investigados em detalhe, resultados de
validação): `doc_voronoi/relatorio_tecnico/` (LaTeX, compile com `make`;
mantido apenas local, fora do controle de versão). Este README traz só um
resumo operacional; ver também
[`scripts/voronoi/README.md`](../scripts/voronoi/README.md) para a
orquestração ponta-a-ponta.

**Status**: pipeline completo (Fases 1-7) implementado e validado em duas
camadas — numericamente, campo a campo, contra `init.nc`/`lbc.*.nc` reais
de produção (caso SouthAmerica: a maioria dos campos bate exato ou
quase-exato); e funcionalmente, rodando o `mpas_atmosphere` real a partir
desses arquivos e obtendo uma previsão de 24h fisicamente sã, sem erros,
cuja divergência frente à rota WPS cresce de forma suave e limitada ao
longo da integração (padrão esperado de duas trajetórias vizinhas de um
sistema caótico). **Reproduzível pra qualquer malha/experimento**, não só
SouthAmerica: os `config_*` são lidos do `namelist.init_atmosphere` real
do experimento em tempo de execução (`namelist_config.F90`), não fixos no
código. Limitações conhecidas (não implementadas: mistura de terreno de
fronteira, reamostragem vertical de solo, reclassificação de gelo
marinho) documentadas em detalhe no relatório técnico.

Programas novos (`src/*.F90`, buildados via `make`):
1. `hinterp_native` — Fase 1, interpolação horizontal nativa (mesmo motor
   de pesos do `convert_mpas`, `remapper.F90`/`target_mesh.F90`, só
   trocando grade lat-lon por lista de pontos dispersos).
2. `gen_vertical_grid` — Fase 2, grade vertical nativa (`vertical_grid.F90`).
3. `gen_init_native` — Fases 2+3+4+6, escritor completo do `init.nc`
   (`vinterp_native.F90`, `hydrostatic.F90`, `surface_fields.F90`).
4. `gen_lbc_native` — Fase 7 parcial, escritor do `lbc.*.nc` (reusa a
   malha vertical do `init.nc`, não recalcula).

```bash
./hinterp_native <REGION>.static.nc  history.AAAA-MM-DD_HH.00.00.nc  extracted.nc
# gera native_target.nc (campos remapeados pros centros de celula da malha-alvo)

./gen_init_native <REGION>.static.nc  namelist.init_atmosphere  native_target.nc  computed.nc
cp <REGION>.static.nc init_completo.nc && ncks -A computed.nc init_completo.nc
# init_completo.nc = init.nc completo (135 variaveis)

./gen_lbc_native init_completo.nc  namelist.init_atmosphere  native_target_<tempo>.nc  \
                 saida_lbc.nc  'AAAA-MM-DD_HH:MM:SS'
```

O orquestrador completo (recorte de malha → `init.nc`/`lbc.*.nc` →
`mpas_atmosphere` real) está em
[`scripts/voronoi/`](../scripts/voronoi/) — ver o README dessa pasta para
a ordem de execução e as variáveis de ambiente configuráveis.

O pipeline de produção original (`run_pipeline.sh`, seção 2.2, via WPS)
continua presente sem alteração, como referência e para comparação lado a
lado com esta rota nova.

---

## 3. Arquitetura (3 estágios)

```
history.nc (malha nativa MPAS, 55 niveis)
      |
      v
[extract_fields]  -- interpolacao VERTICAL (native levels -> 61 niveis de pressao fixa)
      |             ainda na malha nativa (nCells), sem nenhuma interpolacao horizontal
      v
extracted_fields.nc
      |
      v
[convert_mpas]    -- interpolacao HORIZONTAL (malha nativa -> grade lat-lon regular)
      |             ferramenta externa da NCAR, ja existente, reaproveitada sem modificacao
      v
latlon.nc
      |
      v
[pack_intermediate] -- escreve o formato binario WPS v5 ('WP'), campo por campo/nivel
      |
      v
<PREFIXO>:AAAA-MM-DD_HH  -- pronto para config_met_prefix do init_atmosphere_model
```

Por que essa ordem (vertical primeiro, depois horizontal)? Porque a
interpolação vertical é uma operação **por coluna**, independente da malha
horizontal — fazê-la ainda na malha nativa evita qualquer perda de
informação por reamostragem horizontal prévia, e usa exatamente a mesma
lógica que o próprio MPAS usa internamente (ver seção 5).

---

## 4. Funções adaptadas do MPAS-Model — origem e o que mudou

Duas rotinas foram **extraídas literalmente** (não reimplementadas do
zero) do código-fonte oficial do MPAS-Model, porque são exatamente as
mesmas operações que o MPAS já faz internamente para gerar os campos
isobáricos do stream `diagnostics` (`height_500hPa`, `temperature_500hPa`
etc.) — preferimos reaproveitar código já testado em produção a inventar
um método de interpolação próprio.

Fonte original (repositório
[MPAS-Dev/MPAS-Model](https://github.com/MPAS-Dev/MPAS-Model), não incluído
neste repositório — clonar à parte se precisar consultar de novo):

| Nossa cópia | Original | O que mudou |
|---|---|---|
| `src/interp_vertical.F90` :: `interp_tofixed_pressure` | `src/core_atmosphere/diagnostics/mpas_isobaric_diagnostics.F:1005-1091` | Nada na lógica/fórmula. Só `mpas_log_write(...)` → `write(0,*)` (não linkamos o framework do MPAS). |
| `src/interp_vertical.F90` :: `compute_slp` | `src/core_atmosphere/diagnostics/mpas_isobaric_diagnostics.F:1094-1227` | Idem — só troca de logging. |
| `src/mpas_kind_types.F90` | `src/framework/mpas_kind_types.F` | Cópia idêntica (módulo standalone, sem dependências) — só para manter o mesmo `RKIND` (double precision) usado pelas duas rotinas acima. |

O restante (`extract_fields.F90`, `write_intermediate.F90`,
`pack_intermediate.F90`, `pressure_levels.F90`) é código novo, escrito
especificamente para este pipeline.

### 4.1. Ponto de atenção herdado do original (fácil de errar)

`mpas_isobaric_diagnostics.F` **inverte o índice vertical** antes de chamar
`interp_tofixed_pressure` (`kk = nVertLevels+1-k`, linha ~678 do original):
o array nativo do MPAS tem índice 1 na superfície (maior pressão), mas a
rotina de interpolação exige ordem **crescente** de pressão (índice 1 =
topo). `extract_fields.F90` replica essa mesma inversão ao montar
`press_in`/`field_in` — sem isso, o resultado sairia fisicamente invertido
sem nenhum erro de compilação ou execução (bug silencioso).

---

## 5. Método de interpolação vertical — o que é e por que

**Linear em pressão** (não log-pressão), coluna a coluna, entre os dois
níveis de modelo nativos que cercam a pressão-alvo. Extrapolação: abaixo do
nível mais baixo disponível, persistência constante (repete o valor do
nível mais baixo) — sem lapse-rate.

Isso é deliberadamente **a mesma convenção que o próprio MPAS usa** (é
literalmente o código de `mpas_isobaric_diagnostics.F`, ver seção 4) — não
é a convenção mais comum na comunidade mais ampla (NCL `vinth2p`, WRF
`p_interp`, UPP do NCEP costumam usar log-pressão com extrapolação por
lapse-rate de 6.5 K/km abaixo do solo). Optamos por reaproveitar o método
do MPAS porque estamos gerando dado **para o próprio MPAS consumir** — mais
consistência, menos risco de introduzir uma convenção divergente.

### 5.1. Os 61 níveis de pressão-alvo

Não são uma lista genérica (tipo os 21-38 níveis padrão de GFS/CFSR). 55
deles são a **mediana real de pressão de cada um dos 55 níveis de modelo
nativos do MPAS-A**, calculada sobre as células interiores de um recorte
de teste (América do Sul, rodada 2026-01-02_00), preservando o mesmo
espaçamento vertical do modelo (denso na baixa/média troposfera, esparso
no topo). Os outros 6 (1, 2, 3, 5, 7, 10 hPa) são um buffer de margem
vertical no topo — ver §6.1, bug do `extrap_type`, para o porquê. Ver
`src/pressure_levels.F90` para a lista completa e o comentário com a
proveniência exata.

**Por que 55 e não menos:** o manual oficial (`mpas_atmosphere_users_guide`,
seção 7.2.2) usa `config_nfglevels=38` como exemplo padrão (usando GFS como
fonte) — bem mais que os 8 níveis de pressão que o stream `diagnostics`
(`diag.nc`) grava por padrão. Por isso a fonte é o `history.nc` (55 níveis
nativos completos), não o `diag.nc`.

**Comparação direta com um arquivo de produção real** (`ungrib` +
GFS 0.25°, `FILE:2025-12-28_00` de uma rodada operacional, lido com um
parser próprio do formato binário intermediário — ver §6.1 para o motivo):
a estrutura de campos bate integralmente (mesmos pseudo-níveis
200100/201300 Pa, mesma convenção de nomes de solo `SM*/ST*`). O
`EARTH_RADIUS` do arquivo de produção real é **6371.229** km (raio da
própria esfera da malha MPAS, `sphere_radius` no netCDF) — usamos o mesmo
valor, não o 6370.0 legado do WPS/`ungrib`.

Quanto ao alcance vertical: o GFS real vai até **100 Pa = 1 hPa** (34
níveis distintos, de 100 a 100000 Pa), bem além do topo nativo do MPAS
(~12 hPa, `config_ztop=30000m`). Isso não é só uma curiosidade — é a razão
de existirem os 6 níveis de buffer no topo de `plevels_hPa` (ver §6.1,
bug do `extrap_type`): reproduzimos esse mesmo teto (1 a 10 hPa) para dar
ao `init_atmosphere_model` a mesma margem vertical que ele já recebe em
produção.

---

## 6. Campos extraídos/gerados

| Campo (WPS) | Nível(is) | Unidade | Fonte no `history.nc` | Como é obtido |
|---|---|---|---|---|
| `TT` | 61 níveis de pressão | K | `theta`, `pressure` | `T = theta*(p/p0)^(Rd/cp)`, interpolado |
| `UU` / `VV` | 61 níveis de pressão | m/s | `uReconstructZonal/Meridional` | interpolado (`interp_tofixed_pressure`) |
| `GHT` | 61 níveis de pressão | m | `zgrid` | altura do nível de massa = média das 2 interfaces, interpolado |
| `SPECHUMD` | 61 níveis de pressão | kg/kg | `qv` | `q = qv/(1+qv)`, interpolado |
| `RH` | 61 níveis de pressão | % | `relhum` | já em %, só interpolado |
| `TT`/`UU`/`VV`/`SPECHUMD`/`RH` | pseudo-nível 200100 Pa | K, m/s, kg/kg, % | `t2m`,`u10`,`v10`,`q2` | direto (2m/10m); `RH` a 2m via pressão de vapor de `q2`+`psfc` sobre saturação de Bolton |
| `PSFC` | 200100 Pa | Pa | `surface_pressure` | direto |
| `PMSL` | 201300 Pa | Pa | (calculado) | `compute_slp` (seção 4), convertido hPa→Pa |
| `SKINTEMP` | 200100 Pa | K | `skintemp` | direto |
| `SOILHGT` | 200100 Pa | m | `zgrid(1,:)` | altura da superfície (terreno) |
| `LANDSEA` | 200100 Pa | proporção | `xland` | `LANDSEA = 2 - xland` (xland: 1=terra,2=água) |
| `SST` | 200100 Pa | K | `sst` | direto |
| `SNOW` | 200100 Pa | kg/m² | `snow` | direto (equivalente em água) |
| `SEAICE` | 200100 Pa | proporção | `xice` | direto (já fração 0-1) |
| `SM000010`/`SM010040`/`SM040100`/`SM100200` | 200100 Pa | m³/m³ | `smois` (4 camadas) | direto, convenção Noah 10/40/100/200 cm |
| `ST000010`/`ST010040`/`ST040100`/`ST100200` | 200100 Pa | K | `tslb` (4 camadas) | direto |

Todas as unidades foram **conferidas nos atributos `units` reais do
netCDF** (não assumidas), exceto onde indicado como "calculado".

### 6.1. Bugs reais encontrados durante o desenvolvimento (e correção)

- **`PMSL` em hPa em vez de Pa**: `compute_slp` retorna em hPa (mesma
  convenção do original); faltava multiplicar por 100 antes de gravar.
  Corrigido em `extract_fields.F90`.
- **Endianness**: sem `-fconvert=big-endian -frecord-marker=4` no
  `Makefile`, o arquivo era ilegível pelo `init_atmosphere_model` (ver
  seção 1.1).
- **`EARTH_RADIUS`**: usava 6370.0 (legado WPS); corrigido para 6371.229
  (raio real da malha MPAS), após comparar com um arquivo de produção real.
- **`config_nfglevels` do `init_atmosphere_model` (namelist consumidor,
  não deste código)**: precisa contar exatamente os níveis de pressão de
  `plevels_hPa` (atualmente 61, ver bug seguinte) + 1 pseudo-nível de
  superfície `200100`. O pseudo-nível `201300` (`PMSL`) é gravado como um
  campo 2D isolado — como `PSFC`/`SKINTEMP` — e não é uma camada vertical
  interpolável; o `init_atmosphere_model` não o conta. Confirmado ao vivo:
  contar o `201300` a mais faz o modelo ler um nível a mais que o real
  (dado não inicializado) e travar em
  `ERROR: extrap_type == 2 not implemented for target_z >= zf(1,nz)`
  seguido de segfault.

- **Sem margem vertical no topo → mesmo erro `extrap_type == 2`, mesmo com
  `config_nfglevels` correto (2026-09-05)**: os 55 níveis de pressão
  originais de `plevels_hPa` são a *mediana* da pressão de cada nível
  nativo do MPAS, calculada numa rodada de referência. Isso deixa margem
  ~zero no topo: o nível mais alto (12.24 hPa) representa a altura
  *mediana* do último nível de modelo, então em boa parte das células (e
  em rodadas com atmosfera um pouco mais fria/comprimida no topo que a de
  referência) a altura real do topo do domínio MPAS excede a altura do
  topo dos dados de first-guess. O `init_atmosphere_model` não sabe
  extrapolar T acima do topo do first-guess nesse caso (`extrap_type==2`)
  e trava — mesmo com `config_nfglevels` certo, porque a causa não é a
  contagem de níveis, é a cobertura vertical. Confirmado ao vivo: o erro
  persistiu após corrigir `config_nfglevels` para 56.

  **Correção**: adicionados 6 níveis de pressão extras no topo de
  `plevels_hPa` — 1, 2, 3, 5, 7, 10 hPa — os *mesmos* níveis que o
  `ungrib`/GFS de produção já usa acima de 12 hPa (confirmado lendo os
  headers de um `FILE:*` real, §5.1: o GFS vai até 100 Pa = 1 hPa). Não é
  um buffer arbitrário: reproduz o teto vertical que o
  `init_atmosphere_model` já consome sem erro em produção. `N_PLEVELS`
  passou de 55 para 61; `config_nfglevels` correto agora é **62** (61 +
  1 pseudo-nível de superfície). Qualquer mudança em `plevels_hPa` exige
  recompilar o `mpas2intermediate` **e reprocessar todos os arquivos
  `MPAS:*` já gerados** — o formato/conteúdo deles muda.

- **A correção acima sozinha não resolveu nada — mesmo erro, mesmo com
  `N_PLEVELS=61` (2026-09-05, confirmado ao vivo rodando interativamente
  no nó)**: `interp_tofixed_pressure` usa a **mesma fórmula** de
  extrapolação acima do topo para todos os campos, inclusive `GHT`:
  `field_out = field_in(topo) * (pressão_alvo/pressão_topo)`. Essa fórmula
  é plausível para campos que tendem a zero com a pressão, mas é
  **fisicamente invertida para altura**: como `pressão_alvo < pressão_topo`
  nos níveis de buffer, o resultado é uma altura *menor* que a do topo
  nativo, não maior. Ou seja, os 6 níveis de buffer recebiam `GHT` **abaixo**
  de 12.24 hPa — o buffer não aumentava a cobertura vertical nenhum pouco,
  e o `init_atmosphere_model` continuava vendo o mesmo topo de sempre.

  **Primeira tentativa de correção (insuficiente)**: em `extract_fields.F90`,
  depois da chamada padrão de `interp_from_native` para `GHT`, os 6
  primeiros índices de `plevels_hPa` (1-10 hPa) eram recalculados com
  extrapolação hipsométrica isotérmica, ancorada no índice 7 (12.24 hPa,
  assumido como sempre real/interpolado): `z(k) = z_âncora + (Rd·T_âncora/g)
  · ln(p_âncora/p(k))`.

  **Bug 3 (2026-09-05, mesmo dia, ainda): a correção acima também não
  bastou** — confirmado ao vivo rodando interativamente no nó (não via
  job batch), o mesmo erro voltou a ocorrer, agora em índices variados
  (`k=1` numa célula, `k=55` noutra, dependendo da célula). Causa: 12.24 hPa
  é a *mediana* da pressão do nível nativo mais alto **entre células** —
  para ~metade das células, a pressão real do topo nativo *daquela célula
  específica* é **maior** que 12.24 hPa (confirmado numa célula real do
  `history.nc`: 13.10 hPa). Ou seja, o próprio nível "nativo" de 12.24 hPa
  também caía no ramo de extrapolação com a fórmula errada para essa
  célula — só que a correção anterior só cobria os índices 1-6, não o 7.
  Resultado: `GHT(12.24hPa)` saía *menor* que `GHT(14.06hPa)` (interpolação
  real, correta), quebrando monotonicidade exatamente no ponto que a
  correção anterior assumia como seguro.

  **Correção "por célula" (também insuficiente)**: fazer a correção de
  `GHT` **por célula**, comparando cada `plevels_hPa(k)` contra o topo
  nativo *real* daquela célula (`pressure(nVertLevels,iCell)`, sempre
  dado real) em vez de um índice fixo, corrigiu de fato a malha nativa —
  validado numericamente com um `history.nc` real (163842 células):
  **zero inversões reais de altura** em toda a malha global (as "quedas
  planas" remanescentes, ~34% das células, são platôs exatos — diferença
  = 0 — da extrapolação "abaixo do solo" para terreno elevado, esperada
  e tratada do lado consumidor por `config_extrap_airtemp`, não
  relacionada a este bug).

  Mesmo assim, o erro **persistiu** ao rodar o pipeline completo — porque
  esse fix trocava de regime (real vs. extrapolado) em pontos diferentes
  para cada célula, e o `convert_mpas` (próximo estágio, remapeamento
  horizontal malha nativa → grade lat-lon) mistura dados de células
  vizinhas que podem estar em regimes diferentes para o mesmo nível,
  produzindo um perfil não-monotônico no ponto de grade remapeado.

  **Correção definitiva**: usar um **conjunto fixo de índices**
  (`N_ALWAYS_EXTRAP`, os mesmos para toda célula) sempre corrigidos com a
  extrapolação hipsométrica, eliminando a troca de regime espacial. A
  margem foi calibrada medindo a pressão do topo nativo em toda a malha
  global real: nunca excede 13.86 hPa (min 8.44, mediana 12.17) — por
  isso `N_ALWAYS_EXTRAP=8` (cobre até 14.06 hPa, ~0.2 hPa de margem sobre
  o pior caso observado).

- **A causa raiz de verdade era outra: grade lat-lon do `convert_mpas`
  menor que a malha regional real (2026-09-05, mesmo dia)**. Depois das
  três correções acima (todas necessárias, mas insuficientes sozinhas),
  o erro `extrap_type == 2 not implemented for target_z >= zf(1,nz)`
  ainda persistia, agora consistentemente em `k=1` (nível mais baixo, não
  o topo) em poucas células específicas. Lendo o código-fonte real do
  consumidor (`mpas_init_atm_vinterp.F`, `mpas_init_atm_cases.F`, do
  bundle MPAS-JEDI usado para compilar o `init_atmosphere_model`):
  `zf(1,nz)` é literalmente a *altura* do último ponto do array de
  first-guess **depois de ordenado por altura** (`mpas_quicksort`) — ou
  seja, o erro só pode disparar se a maior altura entre os dados daquela
  célula estiver genuinamente baixa/inválida, não por não-monotonicidade
  local (o quicksort já corrige isso). Isso apontou para dado *ausente*,
  não mal-extrapolado.
  
  Medindo `latCell`/`lonCell` direto de `SouthAmerica.static.nc`: a malha
  regional real (incluindo a zona de contorno/relaxamento que o
  MPAS-Limited-Area adiciona ao redor da elipse nominal, não documentada
  no `.pts`) vai de -60.99 a **+31.14** de latitude e de -92.79 a -27.21
  de longitude — vários graus além da grade lat-lon configurada em
  `scripts/02_roda_pipeline_meteorologico.bash` (lat -60/25, lon -90/-30,
  baseada na elipse *nominal*, não na extensão real). 518 das 17064
  células (medido) ficavam fora da grade, sem nenhum dado real do
  `convert_mpas` — exatamente as poucas células que travavam,
  consistentemente, entre execuções.

  **Correção**: `scripts/02_roda_pipeline_meteorologico.bash` agora usa
  os limites REAIS medidos (não a elipse nominal) + margem, com
  `NLAT`/`NLON` ajustados para manter a resolução da grade. Qualquer novo
  recorte de malha deve reconferir a extensão real antes de fixar esses
  limites (comando de verificação documentado no comentário do script).

- **Platôs de `GHT` (persistência constante "abaixo do solo") travam o
  `init_atmosphere_model` de outra forma (2026-09-05, mesmo dia)**: a
  extrapolação "abaixo do nível mais baixo do dado de entrada" de
  `interp_tofixed_pressure` (persistência constante, ver §5 acima) faz os
  últimos níveis de pressão (mais próximos da superfície) ficarem com a
  **mesma altura exata** quando a pressão real de superfície da célula é
  menor que 2+ dos nossos níveis fixos — já tínhamos documentado isso como
  "platô esperado, sem inversão real" (não é o mesmo que uma inversão).
  Isso **também é um bug real**: reproduzido numericamente com dados
  reais, confirmado que o consumidor (`mpas_init_atm_cases.F`, rotina
  "Adjust surface pressure for difference in topography") extrapola
  `log(PSFC)` usando os *dois primeiros pontos* do perfil ordenado por
  altura com uma divisão `(zf(2)-zf(1))` — se esses dois pontos têm a
  mesma altura (nosso platô), a divisão é por zero, dando `Infinity`/`NaN`
  em `PSFC`. Resultado real: ~12% das células da malha regional (2089 de
  17064) saíam com `surface_pressure=NaN` no `init.nc`, causando SIGSEGV
  na inicialização da física do `mpas_atmosphere` (não do
  `init_atmosphere_model` — por isso não aparecia nos logs de erro
  anteriores, só mais adiante no pipeline).

  **Primeira correção (piorou o problema)**: garantir monotonicidade
  estrita de `GHT` com uma perturbação mínima (0.01m) só onde havia
  empate. Resolveu a divisão por zero, mas trocou o bug: quebrar o empate
  com uma diferença de *altura* minúscula entre os dois primeiros pontos,
  mantendo a diferença de *pressão* normal entre eles, produz uma slope
  `log(p)`-vs-altura absurdamente íngreme (ex.: -0.6/metro). Extrapolando
  essa slope pela distância real até o terreno (dezenas a centenas de
  metros), o resultado explode numericamente — confirmado ao vivo:
  `log(psfc)` chegou a 113 (`psfc≈1e49`), pior que o `NaN` original. 31
  células (região andina) continuaram com `surface_pressure` inválido.

  **Como o GFS/`ungrib` real evita isso**: dados de produção (GFS) cobrem
  níveis de pressão até 1000 hPa em todo o globo, inclusive sobre terreno
  elevado onde 1000 hPa fica "debaixo do chão" — o NCEP já extrapola
  esses campos abaixo do terreno com o **método hipsométrico** (lapse-rate
  padrão), nunca persistência constante. Por isso o perfil altura-vs-pressão
  do GFS é sempre suave/contínuo, e a rotina "Adjust surface pressure" do
  MPAS nunca vê esse bug em produção. A fórmula "persistência constante"
  que usamos (`interp_vertical.F90`) foi emprestada do
  `mpas_isobaric_diagnostics.F`, pensada para campos de *saída*/diagnóstico
  em poucos níveis padrão — não para realimentar o `init_atmosphere_model`.
  Usá-la para `GHT` especificamente foi uso indevido dessa fórmula fora do
  contexto para o qual foi desenhada.

  **Correção definitiva**: replicar o que o GFS faz — extrapolação
  hipsométrica (mesma fórmula já usada no topo) para os níveis "abaixo do
  solo", ancorada na pressão/altura/temperatura *reais* do primeiro nível
  nativo de cada célula. Diferente do topo, aqui a condição "abaixo do
  solo" varia muito entre células (pressão de superfície vai de ~300 hPa
  nos Andes a ~1030 hPa ao nível do mar) — um índice fixo descartaria
  dado real demais, então a correção é condicional por célula mesmo (a
  troca de regime espacial é um risco menor aqui: esses pontos nunca são
  usados pelos níveis verticais reais do modelo, só pela extrapolação de
  `PSFC`, que só precisa de uma slope fisicamente razoável). Validado
  numericamente com o `history.nc` completo (163842 células): zero
  não-monotonicidades **e** `GHT` sempre em faixa fisicamente plausível
  (-373m a 48.6km, nenhum valor absurdo).

---

## 7. Ferramentas auxiliares

`tools/rd_intermediate.exe` — lê e imprime o conteúdo de qualquer arquivo
no formato binário intermediário do WPS (campo, unidades, nível, projeção,
min/max/média dos dados). Foi a ferramenta usada para validar, byte a byte,
que a saída do `pack_intermediate` é lida corretamente pelo mesmo parser
que o `init_atmosphere_model` usa. Fonte adaptada em
`tools/rd_intermediate.F.source` (originalmente parte do WPS,
`util/src/rd_intermediate.F`, com um pequeno patch para reconhecer a fonte
"CPTEC/INPE BAM" de um trabalho anterior/abandonado — irrelevante para o
uso atual, mas mantido para rastreabilidade).

Uso:
```bash
./tools/rd_intermediate.exe MPAS:2026-01-02_00
```

---

## 8. Próximo passo

O(s) arquivo(s) `<PREFIXO>:AAAA-MM-DD_HH` gerados aqui são o
`config_met_prefix` do `namelist.init_atmosphere` do `init_atmosphere_model`
(`config_init_case=7` para o primeiro tempo → condição inicial;
`config_init_case=9` para a sequência completa → fronteira lateral, se a
malha-alvo for regional). A malha-alvo (recorte regional ou global) é
preparada separadamente — ver `../MPAS-Limited-Area/HOWTO_RECORTE.md`.

---

## 9. Pontos em aberto no MPAS-Model (upstream) — o que a comunidade já
    sabe, e como resolvemos por conta própria

Depois de fechar as correções da seção 6.1, pesquisamos se os bugs que
encontramos (`extrap_type==2` no topo, platôs de `GHT` abaixo do solo) já
eram conhecidos fora deste projeto — tanto no repositório oficial do
MPAS-Model quanto no fórum de suporte WRF/MPAS-A da NCAR/UCAR. **Resposta:
sim, os dois são bugs/limitações documentados e, até onde encontramos,
ainda sem correção definitiva mesclada no `MPAS-Model` upstream.** Registramos
aqui as fontes, o que cada uma diz, e por que decidimos manter nossa
solução (feita inteiramente no nosso próprio código, sem patch no
`MPAS-Model`) em vez de adotar qualquer coisa que essas fontes sugerem.

### 9.1. GHT abaixo do solo (nosso "Bug 5") = GitHub Issue #1031 do MPAS-Model

Um usuário relatou no fórum exatamente o sintoma que reproduzimos
numericamente (altura de 850 hPa saindo ~3000 m sobre a Groenlândia, e
também sobre os Alpes/Atlas — terreno alto):

> *"I don't think that a pressure as high as 850 hPa can be measured at
> 3000 m?"* — [850 hPa surface too high?](https://forum.mmm.ucar.edu/threads/850-hpa-surface-too-high.12461/)

Resposta de **Michael Duda** (mantenedor do `core_init_atmosphere`/diagnósticos
isobáricos no MPAS-Model):

> *"My guess is that when the 850 hPa surface is below ground, the
> interp_tofixed_pressure routine that is used to produce the
> 'height_XXXhPa' fields at line 710 of isobaric_diagnostics.F is
> returning the lowest model level height. [...] To keep track of this,
> I've created GitHub Issue #1031 in the MPAS-Model repository."*

Isso é a confirmação, pela própria pessoa que escreveu a rotina, do
mecanismo exato do nosso Bug 5: `interp_tofixed_pressure` (a mesma função
que copiamos para `src/interp_vertical.F90`, seção 4) devolve o valor do
nível mais baixo (persistência constante) quando a pressão-alvo está
abaixo do solo, gerando um platô. O Issue #1031 ficou registrado como
"preciso olhar com calma" — não encontramos PR/commit fechando-o no
histórico do `MPAS-Dev/MPAS-Model`.

**Por que não adotamos nada de lá:** não há solução proposta no Issue, só
o diagnóstico. Resolvemos por conta própria com extrapolação hipsométrica
de verdade (§6.1, "Correção definitiva" do platô de GHT) — que é uma
solução mais completa do que existe hoje no próprio MPAS-Model.

**Limitação que persiste, fora do nosso controle:** nossa correção vale
**só para o `GHT` que geramos na etapa de pré-processamento** (a condição
inicial/fronteira lateral, `extract_fields.F90`). A rotina
`interp_tofixed_pressure` original, com o bug do Issue #1031, continua
ativa **dentro do próprio `mpas_atmosphere`** (núcleo de previsão) — é ela
quem calcula `height_850hPa`, `temperature_850hPa`, `relhum_850hPa`,
`uzonal_850hPa`, `umeridional_850hPa`, `dewpoint_850hPa`, `vorticity_850hPa`,
`w_850hPa` (e os mesmos campos em 700/925 hPa) toda vez que o modelo grava
`diag.*.nc` durante uma previsão — código-fonte de terceiros que não
tocamos. **Se algum dia formos plotar esses campos especificamente em
750/850/925 hPa sobre terreno alto (Andes/Altiplano), o mesmo platô do
Issue #1031 vai aparecer ali**, porque é gerado em tempo de execução pelo
modelo, não pela nossa pipeline. Nos gráficos que já produzimos isso não
aconteceu porque usamos `height_500hPa` (raramente abaixo do solo) e
campos de superfície diretos (T2m, PNM, vento 10m, CAPE, OLR, precipitação)
que não passam por essa interpolação isobárica.

Se um dia quisermos eliminar esse artefato também nos diagnósticos da
própria previsão (não só na condição inicial), a correção teria que ser
um patch no `mpas_isobaric_diagnostics.F` do `MPAS-Model` (aplicando a
mesma ideia hipsométrica dentro de `interp_tofixed_pressure`) — escopo
maior, porque essa mesma função também alimenta `mslp`, `t_isobaric` e
`z_isobaric`. **Decisão registrada nesta sessão: não fazer esse patch por
enquanto** — nenhum dos nossos produtos atuais depende de níveis de
pressão baixos (700/850/925 hPa) sobre terreno elevado.

### 9.2. `extrap_type == 2` no topo (nosso "Bug 2/3") — mesmo erro relatado
     por outros usuários, sem correção oficial "de código" que resolva
     sozinha

Três threads do fórum relatam a **mesma mensagem de erro** que tivemos no
início desta jornada (`ERROR: extrap_type == 2 not implemented for
target_z >= zf(1,nz)`):

1. **[Vertical interpolation to GFS hybrid levels](https://forum.mmm.ucar.edu/threads/vertical-interpolation-to-gfs-hybrid-levels.22838/)**
   — o caso mais parecido com o nosso. Resposta do mgduda: sugestão de
   hotfix trocando `>=` por `>` em `mpas_init_atm_cases.F` (permitir
   prosseguir sem extrapolar quando as alturas são exatamente iguais), e
   alternativa de reduzir `config_ztop` em ~0.1 m. **O usuário testou os
   dois e o erro continuou.** A causa raiz de verdade, que ele mesmo
   encontrou, foi outra: *"I eventually figured out that the GFS analysis
   I was making IC's from didn't contain all of the levels. I would check
   your ERA5 analysis' vertical level info with wgrib2."* — ou seja,
   **dado de entrada sem cobertura vertical suficiente**, exatamente o
   diagnóstico do nosso Bug 2 (§6.1), e exatamente a metodologia que já
   estávamos usando (ler o `FILE:*` real de produção para descobrir o teto
   verdadeiro do GFS, em vez de adivinhar).

2. **[ERROR: extrap_type == 2 ... with GFS data for init_atmosphere](https://forum.mmm.ucar.edu/threads/error-extrap_type-2-not-implemented-for-target_z-zf-1-nz-with-gfs-data-for-init_atmosphere.27755/)**
   — mesma mensagem, causa raiz completamente diferente: o `WPS` do
   usuário tinha sido compilado com um compilador Fortran divergente do
   `gfortran` usado no `MPAS-Model`, corrompendo silenciosamente o
   binário intermediário. Resolvido recompilando o `WPS` com o compilador
   certo. **Relevante para nós como item de checklist futuro**, caso o
   erro volte a aparecer depois de alguma mudança de ambiente/compilador:
   confirmar que `mpas2intermediate` e o `init_atmosphere_model` foram
   compilados com o mesmo `gfortran` (o Makefile deste projeto já força
   `-fconvert=big-endian -frecord-marker=4`, seção 1.1, exatamente para
   evitar esse tipo de incompatibilidade).

3. **[MPAS initialization with lapse-rate when levels go above model top](https://forum.mmm.ucar.edu/threads/mpas-initialization-with-lapse-rate-when-levels-go-above-model-top.28140/)**
   — thread mais recente, sem resolução final registrada. Um usuário
   (`Benr`) propôs ao próprio time do MPAS-Model duas alternativas de
   engenharia — (a) logar um erro mais informativo e cair de volta
   (fallback) para extrapolação `constant` automaticamente, ou (b) falhar
   de forma mais clara/abrupta — nenhuma das duas foi implementada até
   onde encontramos. A recomendação prática de **Ming Chen** (também
   ligado ao desenvolvimento do MPAS) foi usar
   `config_extrap_airtemp = 'constant'`/`'linear'` em vez de `'lapse-rate'`,
   **ou** *"usar dados com nível superior maior que o topo do MPAS"* —
   citando especificamente usar níveis de modelo do GFS (híbridos) em vez
   de níveis de pressão. Essa segunda recomendação é, na prática, a mesma
   ideia por trás do nosso Bug 2/3: **garantir que o dado de entrada tenha
   teto vertical acima do topo real do domínio MPAS**, só que a
   implementamos mantendo o formato de níveis de pressão (mais simples de
   gerar a partir da malha nativa do MPAS global) e adicionando margem
   real (1–10 hPa, calibrada pelo teto real do GFS) em vez de trocar para
   níveis híbridos.

**Por que não adotamos o hotfix `>=`→`>`:** o próprio autor do fórum (caso
1) testou e não resolveu — o hotfix só cobre o caso de igualdade exata de
altura, que não é o problema de fundo (falta de margem/cobertura). Como já
tínhamos a causa raiz certa (Bug 2) e a corrigimos direto no dado de
entrada, aplicar esse hotfix no código do `MPAS-Model` seria uma camada
de segurança redundante, sem necessidade comprovada. Fica registrado aqui
como opção conhecida, caso um teto de domínio (`config_ztop`) muito mais
alto no futuro volte a expor esse limite mesmo com nossa margem atual de
1 hPa.

### 9.3. Referências adicionais da comunidade, não aplicadas diretamente

- **[To obtain data for more isobaric levels in MPAS model](https://forum.mmm.ucar.edu/threads/to-obtain-data-for-more-isobaric-levels-in-mpas-model.23154/)**
  — mostra como estender o número de níveis de pressão do stream de
  diagnósticos da própria previsão (`Registry_isobaric.xml` +
  `isobaric_diagnostics.F`, `nIsoLevelsT`/`t_iso_levels`). Não usamos isso
  porque nosso pipeline (`plevels_hPa`, `src/pressure_levels.F90`) já
  define os próprios níveis-alvo de forma independente, para a condição
  inicial — mas é a referência certa se algum dia quisermos mais níveis
  de saída na *previsão* (`diag.*.nc`), não na condição inicial.
- Comparações com **FV3** (extrapolação de `pressfc` com lapse-rate padrão
  de atmosfera dos EUA, interpolação vetorial de vento) e **WRF**
  (`extrap_type`/`t_extrap_type` configuráveis pelo usuário) reforçam que
  a família de solução "extrapolação física baseada em taxa de
  lapso/hipsometria, em vez de persistência ou redução proporcional" é a
  prática consolidada na área — o que dá suporte independente à escolha
  que já tínhamos feito para o Bug 3/5, sem que nenhuma dessas fontes
  tenha sido usada como base de código.

### 9.4. Resumo para quem for mexer nisso depois

| Bug nosso | Confirmado como bug conhecido? | Corrigido onde | Ainda em aberto? |
|---|---|---|---|
| GHT invertido acima do topo (Bug 3) | Sim, mesma fórmula do Issue #1031/`isobaric_diagnostics.F` | `extract_fields.F90` (nossa pipeline) | Não, para a condição inicial. Sim, para `height_XXXhPa` da própria previsão (não corrigido, é código de terceiros). |
| Platô de GHT abaixo do solo (Bug 5) | Sim, GitHub Issue #1031 (MPAS-Dev/MPAS-Model), sem PR de correção conhecido | `extract_fields.F90` (nossa pipeline) | Idem acima. |
| `extrap_type==2` sem margem no topo (Bug 2) | Sim, mesma mensagem de erro relatada por outros usuários no fórum, sem hotfix de código que resolva sozinho | `pressure_levels.F90` (margem real de 1–10 hPa) | Não, salvo se `config_ztop` mudar para muito acima do teto atual. |
| Regime-switching espacial (Bug 4) | Não encontramos relato equivalente na comunidade (specific ao nosso pipeline de 2 estágios: extração + `convert_mpas`) | `extract_fields.F90` (`N_ALWAYS_EXTRAP` fixo) | Não. |
