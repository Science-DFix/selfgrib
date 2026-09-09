#!/bin/bash
# ==============================================================================
# 06_roda_previsao_native.bash — Fase 7: roda o mpas_atmosphere (nucleo de
# previsao) de VERDADE a partir do init.nc/lbc.*.nc gerados pela rota nativa
# Voronoi (voronoi/04_gera_init_native.bash + voronoi/05_gera_lbc_native.bash),
# em vez dos gerados pelo init_atmosphere_model/WPS.
#
# E' uma copia quase identica de scripts/05_roda_previsao.bash (mesmos
# namelist/streams/executavel/tabelas de fisica) -- SO' os caminhos de
# entrada mudam (INIT_FILE/DIR_LBC apontam pros diretorios *_native).
# Ver scripts/05_roda_previsao.bash para o racional completo de cada
# opcao de namelist/stream (invariant/da_state removidos, config_apply_lbcs
# obrigatorio, etc.) -- nao duplicado aqui.
#
# Pre-requisitos:
#   - <REGION_NAME>.init.nc nativo (voronoi/04_gera_init_native.bash)
#   - <REGION_NAME>.graph.info.part.<NP_RUN> (scripts/01_recorta_regiao.bash)
#   - lbc.*.nc nativos cobrindo START_TIME..START_TIME+RUN_DURATION
#     (voronoi/05_gera_lbc_native.bash)
#
# Objetivo: comparar a saida (history.*.nc) desta rodada contra a rodada de
# referencia ja documentada no README principal (docs/resultados/), gerada
# pela rota WPS a partir do MESMO caso -- se a previsao sair fisicamente
# sa (sem NaN/blowup) e proxima da referencia, fecha a validacao da Fase 7.
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

# --- init.nc/lbc.*.nc NATIVOS (voronoi/04_.../05_...) ---
INIT_FILE="${INIT_FILE:-${DIR_MALHA}/init_run_native/${REGION_NAME}.init.nc}"
DIR_LBC="${DIR_LBC:-${DIR_MALHA}/lbc_run_native}"
LBC_INPUT_INTERVAL="${LBC_INPUT_INTERVAL:-6:00:00}"

# --- Executável do mpas_atmosphere (mesmo build single precision) ---
DIR_EXE="${DIR_EXE:-/lustre/projetos/satdas/diego_workdir/build-mpich-single/bin}"
DIR_PHYSICS="${DIR_PHYSICS:-/lustre/projetos/satdas/diego_workdir/build-mpich-single/_deps/mpas_data-src/atmosphere/physics_wrf/files}"

# --- Parâmetros da previsão ---
START_TIME="${START_TIME:-2026-01-01_00:00:00}"
RUN_DURATION="${RUN_DURATION:-1_00:00:00}"
OUTPUT_INTERVAL="${OUTPUT_INTERVAL:-01:00:00}"
DIAG_INTERVAL="${DIAG_INTERVAL:-01:00:00}"
DT="${DT:-360}"
RADT_INTERVAL="${RADT_INTERVAL:-00:30:00}"
NP_RUN="${NP_RUN:-32}"

# --- Diretório de trabalho da rodada (separado da rota WPS, pra comparar) ---
WORK_DIR="${WORK_DIR:-${DIR_MALHA}/forecast_run_native}"

# --- Validações ---
GRAPH_PART="${DIR_MALHA}/${REGION_NAME}.graph.info.part.${NP_RUN}"
[ -f "$INIT_FILE" ]  || { echo "ERRO: init.nc nativo não encontrado: $INIT_FILE (rode voronoi/04_gera_init_native.bash primeiro)"; exit 1; }
[ -f "$GRAPH_PART" ] || { echo "ERRO: graph.info particionado não encontrado: $GRAPH_PART"; exit 1; }
[ -f "${FILE_BASE_ATM}/namelist.atmosphere" ] || { echo "ERRO: template não encontrado: ${FILE_BASE_ATM}/namelist.atmosphere"; exit 1; }
[ -f "${FILE_BASE_ATM}/streams.atmosphere" ]  || { echo "ERRO: template não encontrado: ${FILE_BASE_ATM}/streams.atmosphere"; exit 1; }
[ -x "${DIR_EXE}/mpas_atmosphere" ] || { echo "ERRO: executável não encontrado: ${DIR_EXE}/mpas_atmosphere"; exit 1; }

N_LBC=$(ls "${DIR_LBC}"/lbc.*.nc 2>/dev/null | wc -l)
[ "$N_LBC" -gt 0 ] || { echo "ERRO: nenhum lbc.*.nc encontrado em $DIR_LBC (rode voronoi/05_gera_lbc_native.bash primeiro)"; exit 1; }

OUT_HISTORY_GLOB="${WORK_DIR}/history.*.nc"

echo "--- mpas_atmosphere (previsão, Fase 7 -- rota nativa Voronoi) [${REGION_NAME}] ---"
echo "  init.nc (nativo) : ${INIT_FILE}"
echo "  LBC (nativo)     : ${DIR_LBC} (${N_LBC} arquivos lbc.*.nc, a cada ${LBC_INPUT_INTERVAL})"
echo "  start            : ${START_TIME}"
echo "  duração          : ${RUN_DURATION}"
echo "  NP               : ${NP_RUN}"
echo "  Saída            : ${WORK_DIR}/history.*.nc"

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

# --- Condição de contorno lateral (nativa) ---
for f in "${DIR_LBC}"/lbc.*.nc; do
    ln -sf "$f" "$(basename "$f")"
done

# --- Tabelas de física (mesmo build usado para compilar o executável) ---
for f in "${DIR_PHYSICS}"/*.TBL "${DIR_PHYSICS}"/*.DBL \
          "${DIR_PHYSICS}"/*DATA "${DIR_PHYSICS}"/VERSION \
          "${DIR_PHYSICS}"/COMPATIBILITY; do
    [ -e "$f" ] && ln -sf "$f" ./
done
ln -sf "${DIR_PHYSICS}/RRTMG_SW_DATA" ./RRTMG_SW_DATA
ln -sf "${DIR_PHYSICS}/RRTMG_LW_DATA" ./RRTMG_LW_DATA

# --- namelist.atmosphere (mesmas opções de scripts/05_roda_previsao.bash) ---
cp -f "${FILE_BASE_ATM}/namelist.atmosphere" .
sed -i -E "s|config_start_time\s*=\s*'[^']*'|config_start_time = '${START_TIME}'|"              namelist.atmosphere
sed -i -E "s|config_run_duration\s*=\s*'[^']*'|config_run_duration = '${RUN_DURATION}'|"        namelist.atmosphere
sed -i -E "s|config_dt\s*=\s*[0-9.]+|config_dt = ${DT}.0|"                                      namelist.atmosphere
sed -i -E "s|config_radtlw_interval\s*=\s*'[^']*'|config_radtlw_interval = '${RADT_INTERVAL}'|" namelist.atmosphere
sed -i -E "s|config_radtsw_interval\s*=\s*'[^']*'|config_radtsw_interval = '${RADT_INTERVAL}'|" namelist.atmosphere
sed -i "s/^\([[:space:]]*config_block_decomp_file_prefix[[:space:]]*=\).*/\1 '${REGION_NAME}.graph.info.part.',/" namelist.atmosphere
sed -i -E "s|config_apply_lbcs\s*=\s*\S+|config_apply_lbcs = true|"                             namelist.atmosphere
sed -i -E "s|config_jedi_da\s*=\s*\S+|config_jedi_da = false|"                                  namelist.atmosphere

# --- streams.atmosphere ---
cp -f "${FILE_BASE_ATM}/streams.atmosphere" .
cp -f "${FILE_BASE_ATM}"/stream_list.atmosphere.* .
sed -i "s/x1\.[0-9]\+\.init\.nc/${REGION_NAME}.init.nc/" streams.atmosphere
sed -i "/stream name=\"output\"/,/<\/stream>/ s|output_interval=\"[^\"]*\"|output_interval=\"${OUTPUT_INTERVAL}\"|" streams.atmosphere
sed -i "/stream name=\"diagnostics\"/,/<\/stream>/ s|output_interval=\"[^\"]*\"|output_interval=\"${DIAG_INTERVAL}\"|" streams.atmosphere
sed -i '/<immutable_stream name="invariant"/,/\/>/d' streams.atmosphere
sed -i '/<immutable_stream name="da_state"/,/\/>/d' streams.atmosphere
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
    echo ""
    echo "Compare contra a referência (rota WPS, mesmo caso, já documentada"
    echo "no README principal / docs/resultados/): ${DIR_MALHA}/forecast_run/history.*.nc"
else
    echo "--- ERRO: nenhum history.*.nc gerado ---"
    tail -20 log.atmosphere.0000.err 2>/dev/null
    exit 1
fi
