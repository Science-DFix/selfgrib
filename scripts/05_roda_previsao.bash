#!/bin/bash
# ==============================================================================
# 05_roda_previsao.bash — Roda o mpas_atmosphere (nucleo de previsao) para
# gerar a previsao a partir do init.nc de uma malha regional recortada
# (MPAS-Limited-Area), adaptando ../../../scripts/run_mpas_forecast.bash
# (producao, malha global x1.163842) para a malha SouthAmerica.
#
# Pre-requisitos (produzidos pelas etapas anteriores):
#   - <REGION_NAME>.init.nc (ver scripts/03_roda_init_atmosphere.bash)
#   - <REGION_NAME>.graph.info.part.<NP_RUN> (ver scripts/01_recorta_regiao.bash)
#   - lbc.*.nc cobrindo START_TIME..START_TIME+RUN_DURATION
#     (ver scripts/04_gera_lbc.bash) -- OBRIGATORIO para malha regional,
#     ver nota abaixo.
#
# Investigado antes de escrever este script (docs/regional_mpas_edi.pdf,
# tutorial oficial NCAR "Regional MPAS", e ver conversa/sessao):
#   - invariant.nc (x1.163842.invariant.nc de producao) NAO e necessario:
#     contem so campos de malha vertical (zgrid, rdzw, ...) e GWD
#     orografico (var2d, oa1-4, ol1-4, ...) que ja saem do
#     init_atmosphere_model quando config_vertical_grid=true (nosso caso,
#     ver 03_roda_init_atmosphere.bash) -- confirmado comparando as
#     variaveis do SouthAmerica.init.nc real com as do invariant.nc de
#     producao: TODAS presentes. O streams.atmosphere declara "invariant"
#     como stream de ENTRADA opcional (fallback), so consultado se um
#     campo faltar no stream "input" (init.nc) -- como nao falta nada,
#     nao precisamos gera-lo nem linka-lo.
#   - config_apply_lbcs=true e OBRIGATORIO para qualquer malha regional
#     (com bdyMaskCell > 0 em alguma celula, gerado pelo
#     MPAS-Limited-Area). Confirmado no manual: se config_apply_lbcs=false
#     numa malha com bdyMaskCell, o modelo PARA com erro fatal
#     "ERROR: Boundary cells found in the bdyMaskCell field, but
#     config_apply_lbcs = false." -- ou seja, NAO e uma opcao de
#     qualidade, e um requisito. Precisa do stream "lbc_in" (ver abaixo)
#     e dos arquivos lbc.*.nc de 04_gera_lbc.bash.
#   - build-mpich-single (mesmo build usado no 03_/04_) tem tanto
#     mpas_init_atmosphere quanto mpas_atmosphere, os dois em precisao
#     SIMPLES (MPAS_DOUBLE_PRECISION=OFF) -- usado aqui em vez do
#     build-mpich de producao (double precision) para bater com a
#     precisao do SouthAmerica.init.nc/lbc.*.nc ja gerados.
#
# Variáveis de entrada/saída são todas configuráveis por ambiente (env vars).
# ==============================================================================

set -euo pipefail

# --- Ambiente do cluster (módulos, MPI, NetCDF) ---
ENV_ALL="${ENV_ALL:-/lustre/projetos/satdas/diego_workdir/env_wrf_wps.bash}"
[ -f "$ENV_ALL" ] && source "$ENV_ALL"

# --- Templates de namelist/streams (mesmos usados em produção) ---
FILE_BASE_ATM="${FILE_BASE_ATM:-/lustre/projetos/satdas/diego_workdir/SOURCE/FILE_BASE/core_atmosphere}"

# --- Malha regional recortada (ver scripts/01_recorta_regiao.bash) ---
DIR_MALHA="${DIR_MALHA:-/lustre/projetos/satdas/diego_workdir/SOURCE/ungrib_to_mpas/recortes/SouthAmerica}"
REGION_NAME="${REGION_NAME:-SouthAmerica}"

# --- init.nc de entrada (ver scripts/03_roda_init_atmosphere.bash) ---
INIT_FILE="${INIT_FILE:-${DIR_MALHA}/init_run/${REGION_NAME}.init.nc}"

# --- Arquivos de condição de contorno lateral (ver scripts/04_gera_lbc.bash) ---
DIR_LBC="${DIR_LBC:-${DIR_MALHA}/lbc_run}"
# Precisa bater EXATAMENTE com LBC_INTERVAL_HHMMSS usado em 04_gera_lbc.bash,
# senao o modelo trava com "Failed to process LBC data at next time after ...".
LBC_INPUT_INTERVAL="${LBC_INPUT_INTERVAL:-6:00:00}"

# --- Executável do mpas_atmosphere -- mesmo build (single precision) do
#     init_atmosphere_model, ver comentario acima ---
DIR_EXE="${DIR_EXE:-/lustre/projetos/satdas/diego_workdir/build-mpich-single/bin}"
DIR_PHYSICS="${DIR_PHYSICS:-/lustre/projetos/satdas/diego_workdir/build-mpich-single/_deps/mpas_data-src/atmosphere/physics_wrf/files}"

# --- Parâmetros da previsão -- duração default (1 dia) bate com o período
#     padrão de LBC gerado por 04_gera_lbc.bash (LBC_START..LBC_STOP) ---
START_TIME="${START_TIME:-2026-01-01_00:00:00}"
RUN_DURATION="${RUN_DURATION:-1_00:00:00}"
OUTPUT_INTERVAL="${OUTPUT_INTERVAL:-01:00:00}"
DIAG_INTERVAL="${DIAG_INTERVAL:-01:00:00}"
DT="${DT:-360}"                                  # mesma resolucao horizontal da malha global (60km)
RADT_INTERVAL="${RADT_INTERVAL:-00:30:00}"
NP_RUN="${NP_RUN:-32}"

# --- Diretório de trabalho da rodada ---
WORK_DIR="${WORK_DIR:-${DIR_MALHA}/forecast_run}"

# --- Validações ---
GRAPH_PART="${DIR_MALHA}/${REGION_NAME}.graph.info.part.${NP_RUN}"
[ -f "$INIT_FILE" ]  || { echo "ERRO: init.nc não encontrado: $INIT_FILE (rode 03_roda_init_atmosphere.bash primeiro)"; exit 1; }
[ -f "$GRAPH_PART" ] || { echo "ERRO: graph.info particionado não encontrado: $GRAPH_PART"; exit 1; }
[ -f "${FILE_BASE_ATM}/namelist.atmosphere" ] || { echo "ERRO: template não encontrado: ${FILE_BASE_ATM}/namelist.atmosphere"; exit 1; }
[ -f "${FILE_BASE_ATM}/streams.atmosphere" ]  || { echo "ERRO: template não encontrado: ${FILE_BASE_ATM}/streams.atmosphere"; exit 1; }
[ -x "${DIR_EXE}/mpas_atmosphere" ] || { echo "ERRO: executável não encontrado: ${DIR_EXE}/mpas_atmosphere"; exit 1; }

N_LBC=$(ls "${DIR_LBC}"/lbc.*.nc 2>/dev/null | wc -l)
[ "$N_LBC" -gt 0 ] || { echo "ERRO: nenhum lbc.*.nc encontrado em $DIR_LBC (rode 04_gera_lbc.bash primeiro)"; exit 1; }

OUT_HISTORY_GLOB="${WORK_DIR}/history.*.nc"

echo "--- mpas_atmosphere (previsão, com LBC) [${REGION_NAME}] ---"
echo "  init.nc        : ${INIT_FILE}"
echo "  LBC            : ${DIR_LBC} (${N_LBC} arquivos lbc.*.nc, a cada ${LBC_INPUT_INTERVAL})"
echo "  start          : ${START_TIME}"
echo "  duração        : ${RUN_DURATION}"
echo "  NP             : ${NP_RUN}"
echo "  Saída          : ${WORK_DIR}/history.*.nc"

if ls ${OUT_HISTORY_GLOB} &>/dev/null; then
    echo "Já existem arquivos history.*.nc em ${WORK_DIR} — nada a fazer."
    ls -lh ${OUT_HISTORY_GLOB}
    exit 0
fi

mkdir -p "$WORK_DIR" && cd "$WORK_DIR"

# --- Malha, dados iniciais e decomposição ---
ln -sf "$INIT_FILE" "${REGION_NAME}.init.nc"
ln -sf "$GRAPH_PART" .
ln -sf "${DIR_EXE}/mpas_atmosphere" .

# --- Condição de contorno lateral ---
for f in "${DIR_LBC}"/lbc.*.nc; do
    ln -sf "$f" "$(basename "$f")"
done

# --- Tabelas de física (mesmo build usado para compilar o executável) ---
for f in "${DIR_PHYSICS}"/*.TBL "${DIR_PHYSICS}"/*.DBL \
          "${DIR_PHYSICS}"/*DATA "${DIR_PHYSICS}"/VERSION \
          "${DIR_PHYSICS}"/COMPATIBILITY; do
    [ -e "$f" ] && ln -sf "$f" ./
done
# single precision (ver cabecalho): usa as tabelas RRTMG sem sufixo .DBL
ln -sf "${DIR_PHYSICS}/RRTMG_SW_DATA" ./RRTMG_SW_DATA
ln -sf "${DIR_PHYSICS}/RRTMG_LW_DATA" ./RRTMG_LW_DATA

# --- namelist.atmosphere ---
cp -f "${FILE_BASE_ATM}/namelist.atmosphere" .
sed -i -E "s|config_start_time\s*=\s*'[^']*'|config_start_time = '${START_TIME}'|"              namelist.atmosphere
sed -i -E "s|config_run_duration\s*=\s*'[^']*'|config_run_duration = '${RUN_DURATION}'|"        namelist.atmosphere
sed -i -E "s|config_dt\s*=\s*[0-9.]+|config_dt = ${DT}.0|"                                      namelist.atmosphere
sed -i -E "s|config_radtlw_interval\s*=\s*'[^']*'|config_radtlw_interval = '${RADT_INTERVAL}'|" namelist.atmosphere
sed -i -E "s|config_radtsw_interval\s*=\s*'[^']*'|config_radtsw_interval = '${RADT_INTERVAL}'|" namelist.atmosphere
sed -i "s/^\([[:space:]]*config_block_decomp_file_prefix[[:space:]]*=\).*/\1 '${REGION_NAME}.graph.info.part.',/" namelist.atmosphere
# Unica opcao de namelist que ativa a simulacao regional -- OBRIGATORIA
# (ver cabecalho): sem isso o modelo trava assim que ve bdyMaskCell>0.
sed -i -E "s|config_apply_lbcs\s*=\s*\S+|config_apply_lbcs = true|"                             namelist.atmosphere
sed -i -E "s|config_jedi_da\s*=\s*\S+|config_jedi_da = false|"                                  namelist.atmosphere

# --- streams.atmosphere ---
cp -f "${FILE_BASE_ATM}/streams.atmosphere" .
cp -f "${FILE_BASE_ATM}"/stream_list.atmosphere.* .
sed -i "s/x1\.[0-9]\+\.init\.nc/${REGION_NAME}.init.nc/" streams.atmosphere
sed -i "/stream name=\"output\"/,/<\/stream>/ s|output_interval=\"[^\"]*\"|output_interval=\"${OUTPUT_INTERVAL}\"|" streams.atmosphere
sed -i "/stream name=\"diagnostics\"/,/<\/stream>/ s|output_interval=\"[^\"]*\"|output_interval=\"${DIAG_INTERVAL}\"|" streams.atmosphere
# remove o stream "invariant" (immutable, input) -- desnecessario, ver
# comentario no cabecalho: nosso init.nc ja tem todos os campos que ele
# forneceria, e nao geramos/linkamos um invariant.nc para esta malha.
sed -i '/<immutable_stream name="invariant"/,/\/>/d' streams.atmosphere
# remove tambem o stream "da_state" (pacote jedi_da) -- confirmado ao
# vivo que desativar config_jedi_da=false (namelist) NAO desativa esse
# stream (o framework continua tentando le-lo/escreve-lo): o log mostrava
# "Read 'da_state' input stream valid at 0000-01-01_00:00:00" (data
# zerada/invalida, tempo de leitura ~0s -- sinal de dado nao inicializado)
# imediatamente seguido de SIGSEGV na inicializacao da fisica. Removida a
# declaracao do stream de vez (nao so desativando via namelist) -- nao
# estamos fazendo assimilacao MPAS-JEDI, so um forecast simples a partir
# do init.nc + LBC.
sed -i '/<immutable_stream name="da_state"/,/\/>/d' streams.atmosphere
# adiciona o stream "lbc_in" (input) -- o template de producao ja tem um
# stream "lbc_in" com pacote "limited_area" e input_interval="3:00:00"
# fixo; sobrescrevemos o input_interval para bater com o intervalo real
# dos nossos lbc.*.nc (LBC_INPUT_INTERVAL, ver cabecalho).
if grep -q 'name="lbc_in"' streams.atmosphere; then
    sed -i "/name=\"lbc_in\"/,/\/>/ s|input_interval=\"[^\"]*\"|input_interval=\"${LBC_INPUT_INTERVAL}\"|" streams.atmosphere
else
    sed -i "/<\/streams>/i\\
<immutable_stream name=\"lbc_in\"\\
                  type=\"input\"\\
                  filename_template=\"lbc.\$Y-\$M-\$D_\$h.nc\"\\
                  filename_interval=\"input_interval\"\\
                  packages=\"limited_area\"\\
                  input_interval=\"${LBC_INPUT_INTERVAL}\" />\\
" streams.atmosphere
fi

echo "--- Rodando mpas_atmosphere com ${NP_RUN} processos ---"
ulimit -s unlimited
export GFORTRAN_CONVERT_UNIT='big_endian:101-200'
mpiexec -n "${NP_RUN}" -iface hsn0 -bind-to core -launcher fork ./mpas_atmosphere

if ls ${OUT_HISTORY_GLOB} &>/dev/null; then
    echo "--- SUCESSO ---"
    ls -lh ${OUT_HISTORY_GLOB}
else
    echo "--- ERRO: nenhum history.*.nc gerado ---"
    tail -20 log.atmosphere.0000.err 2>/dev/null
    exit 1
fi
