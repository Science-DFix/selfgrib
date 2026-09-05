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

  **Correção definitiva**: a correção de `GHT` agora é feita **por
  célula**, comparando cada `plevels_hPa(k)` contra o topo nativo *real*
  daquela célula (`pressure(nVertLevels,iCell)`, sempre dado real, nunca
  extrapolado) em vez de um índice fixo do array — pode ser 5, 6, 7 níveis
  recalculados dependendo da célula. Não depende mais de nenhuma constante
  tipo `N_BUFFER_TOP`. Validado numericamente com um `history.nc` real
  (163842 células, malha global): **zero inversões reais de altura** em
  toda a malha (as poucas "quedas planas" que aparecem, ~34% das células,
  em níveis de baixa/média troposfera, são platôs exatos — diferença = 0,
  não inversão — da extrapolação "abaixo do solo" documentada em
  `interp_vertical.F90` para células de terreno elevado; comportamento
  esperado, tratado do lado consumidor por `config_extrap_airtemp`, não
  relacionado a este bug).

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
