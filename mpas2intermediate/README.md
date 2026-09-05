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
[extract_fields]  -- interpolacao VERTICAL (native levels -> 55 niveis de pressao fixa)
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

### 5.1. Os 55 níveis de pressão-alvo

Não são uma lista genérica (tipo os 21-38 níveis padrão de GFS/CFSR). São a
**mediana real de pressão de cada um dos 55 níveis de modelo nativos do
MPAS-A**, calculada sobre as células interiores de um recorte de teste
(América do Sul, rodada 2026-01-02_00). Preserva o mesmo espaçamento
vertical do modelo (denso na baixa/média troposfera, esparso no topo) — ver
`src/pressure_levels.F90` para a lista completa e o comentário com a
proveniência exata.

**Por que 55 e não menos:** o manual oficial (`mpas_atmosphere_users_guide`,
seção 7.2.2) usa `config_nfglevels=38` como exemplo padrão (usando GFS como
fonte) — bem mais que os 8 níveis de pressão que o stream `diagnostics`
(`diag.nc`) grava por padrão. Por isso a fonte é o `history.nc` (55 níveis
nativos completos), não o `diag.nc`.

**Comparação direta com um arquivo de produção real** (`ungrib` +
GFS 0.25°, `FILE:2025-12-28_00` de uma rodada operacional): a estrutura de
campos bate integralmente (mesmos pseudo-níveis 200100/201300 Pa, mesma
convenção de nomes de solo `SM*/ST*`). Duas diferenças, ambas esperadas:
nosso alcance vertical vai só até ~12 hPa (o próprio topo do MPAS,
`config_ztop=30000m`) contra 1 hPa do GFS (que o MPAS nunca usaria mesmo
assim); e o `EARTH_RADIUS` do arquivo de produção real é **6371.229** km
(raio da própria esfera da malha MPAS, `sphere_radius` no netCDF) — usamos
o mesmo valor, não o 6370.0 legado do WPS/`ungrib`.

---

## 6. Campos extraídos/gerados

| Campo (WPS) | Nível(is) | Unidade | Fonte no `history.nc` | Como é obtido |
|---|---|---|---|---|
| `TT` | 55 níveis de pressão | K | `theta`, `pressure` | `T = theta*(p/p0)^(Rd/cp)`, interpolado |
| `UU` / `VV` | 55 níveis de pressão | m/s | `uReconstructZonal/Meridional` | interpolado (`interp_tofixed_pressure`) |
| `GHT` | 55 níveis de pressão | m | `zgrid` | altura do nível de massa = média das 2 interfaces, interpolado |
| `SPECHUMD` | 55 níveis de pressão | kg/kg | `qv` | `q = qv/(1+qv)`, interpolado |
| `RH` | 55 níveis de pressão | % | `relhum` | já em %, só interpolado |
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
