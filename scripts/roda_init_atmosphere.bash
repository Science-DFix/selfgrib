#!/bin/bash
# ==============================================================================
# roda_init_atmosphere.bash — Roda o init_atmosphere_model para gerar o
# init.nc de uma malha regional recortada (MPAS-Limited-Area), usando os
# arquivos meteorológicos intermediários gerados pelo pipeline selfgrib
# (mpas2intermediate) como fonte, em vez de GFS/ungrib.
#
# Pré-requisitos (produzidos pelas etapas anteriores):
#   - <REGION_NAME>.static.nc + <REGION_NAME>.graph.info.part.<NP_RUN>
#     (ver scripts/recorta_regiao.bash)
#   - <PREFIXO>:AAAA-MM-DD_HH em DIR_MET
#     (ver scripts/roda_pipeline_meteorologico.bash)
#
# Adapta os templates de namelist/streams do init_atmosphere_model:
#   - config_met_prefix: 'FILE' -> PREFIXO ('MPAS')
#   - config_nfglevels: 38 (GFS) -> N_PLEVELS (55, níveis fixos do selfgrib
#     — ver mpas2intermediate/src/pressure_levels.F90)
#   - config_block_decomp_file_prefix e filename_template dos streams:
#     x1.<malha global> -> <REGION_NAME> (malha recortada)
#
# Variáveis de entrada/saída são todas configuráveis por ambiente (env vars).
# ==============================================================================

set -euo pipefail

# --- Ambiente do cluster (módulos, MPI, NetCDF) ---
ENV_ALL="${ENV_ALL:-/lustre/projetos/satdas/diego_workdir/env_wrf_wps.bash}"
[ -f "$ENV_ALL" ] && source "$ENV_ALL"

# --- Templates de namelist/streams (mesmos usados em produção) ---
FILE_BASE_INI="${FILE_BASE_INI:-/lustre/projetos/satdas/diego_workdir/SOURCE/FILE_BASE}"

# --- Malha regional recortada (ver scripts/recorta_regiao.bash) ---
DIR_MALHA="${DIR_MALHA:-/lustre/projetos/satdas/diego_workdir/SOURCE/ungrib_to_mpas/recortes/SouthAmerica}"
REGION_NAME="${REGION_NAME:-SouthAmerica}"

# --- Arquivos meteorológicos intermediários (ver scripts/roda_pipeline_meteorologico.bash) ---
DIR_MET="${DIR_MET:-${DIR_MALHA}/met_intermediate}"
PREFIXO="${PREFIXO:-MPAS}"

# --- Executável do init_atmosphere_model ---
DIR_EXE="${DIR_EXE:-/lustre/projetos/satdas/diego_workdir/build-mpich-single/bin}"

# --- Condição inicial: um único tempo (config_init_case=7) ---
START_TIME="${START_TIME:-2026-01-01_00:00:00}"
NP_RUN="${NP_RUN:-32}"

# --- Constante do selfgrib: número de níveis de pressão fixos gerados
#     (ver mpas2intermediate/src/pressure_levels.F90 :: N_PLEVELS) ---
N_PLEVELS="${N_PLEVELS:-55}"

# --- Diretório de trabalho da rodada ---
WORK_DIR="${WORK_DIR:-${DIR_MALHA}/init_run}"

# --- Validações ---
STATIC_REGIONAL="${DIR_MALHA}/${REGION_NAME}.static.nc"
GRAPH_PART="${DIR_MALHA}/${REGION_NAME}.graph.info.part.${NP_RUN}"
[ -f "$STATIC_REGIONAL" ] || { echo "ERRO: static.nc regional não encontrado: $STATIC_REGIONAL"; exit 1; }
[ -f "$GRAPH_PART" ]      || { echo "ERRO: graph.info particionado não encontrado: $GRAPH_PART (rode recorta_regiao.bash com NP_PARTS=\"... ${NP_RUN} ...\")"; exit 1; }
[ -f "${FILE_BASE_INI}/namelist.init_atmosphere" ] || { echo "ERRO: template não encontrado: ${FILE_BASE_INI}/namelist.init_atmosphere"; exit 1; }
[ -f "${FILE_BASE_INI}/streams.init_atmosphere" ]  || { echo "ERRO: template não encontrado: ${FILE_BASE_INI}/streams.init_atmosphere"; exit 1; }
[ -x "${DIR_EXE}/mpas_init_atmosphere" ] || { echo "ERRO: executável não encontrado: ${DIR_EXE}/mpas_init_atmosphere"; exit 1; }

N_MET=$(ls "${DIR_MET}/${PREFIXO}":* 2>/dev/null | wc -l)
[ "$N_MET" -gt 0 ] || { echo "ERRO: nenhum arquivo ${PREFIXO}:* encontrado em $DIR_MET"; exit 1; }

INIT_FILE="${WORK_DIR}/${REGION_NAME}.init.nc"

echo "--- init_atmosphere_model [${REGION_NAME}] ---"
echo "  Malha regional : ${STATIC_REGIONAL}"
echo "  Meteorologia   : ${DIR_MET} (${N_MET} arquivos ${PREFIXO}:*)"
echo "  start=stop     : ${START_TIME}"
echo "  NP             : ${NP_RUN}"
echo "  Saída          : ${INIT_FILE}"

if [ -f "$INIT_FILE" ] && [ -s "$INIT_FILE" ] && ncdump -h "$INIT_FILE" &>/dev/null; then
    echo "Já existe e é válido: ${INIT_FILE} — nada a fazer."
    ls -lh "$INIT_FILE"
    exit 0
fi

mkdir -p "$WORK_DIR" && cd "$WORK_DIR"

# --- Malha e decomposição ---
ln -sf "$STATIC_REGIONAL" .
ln -sf "$GRAPH_PART" .
ln -sf "${DIR_EXE}/mpas_init_atmosphere" init_atmosphere_model

# --- Dados meteorológicos (selfgrib) ---
mkdir -p met_data
for f in "${DIR_MET}/${PREFIXO}":*; do
    ln -sf "$f" "met_data/$(basename "$f")"
done
ln -sf met_data/"${PREFIXO}":* .

# --- namelist.init_atmosphere ---
cp -f "${FILE_BASE_INI}/namelist.init_atmosphere" .
sed -i "s/^\([[:space:]]*config_start_time[[:space:]]*=\).*/\1 '${START_TIME}',/"                 namelist.init_atmosphere
sed -i "s/^\([[:space:]]*config_stop_time[[:space:]]*=\).*/\1  '${START_TIME}',/"                  namelist.init_atmosphere
sed -i "s/^\([[:space:]]*config_met_prefix[[:space:]]*=\).*/\1   '${PREFIXO}',/"                   namelist.init_atmosphere
sed -i "s/^\([[:space:]]*config_nfglevels[[:space:]]*=\).*/\1     ${N_PLEVELS},/"                  namelist.init_atmosphere
sed -i "s/^\([[:space:]]*config_block_decomp_file_prefix[[:space:]]*=\).*/\1 '${REGION_NAME}.graph.info.part.',/" namelist.init_atmosphere

# --- streams.init_atmosphere ---
cp -f "${FILE_BASE_INI}/streams.init_atmosphere" .
sed -i "s/x1\.[0-9]\+\.static\.nc/${REGION_NAME}.static.nc/" streams.init_atmosphere
sed -i "s/x1\.[0-9]\+\.init\.nc/${REGION_NAME}.init.nc/"     streams.init_atmosphere

echo "--- Rodando init_atmosphere_model com ${NP_RUN} processos ---"
ulimit -s unlimited
mpiexec -n "${NP_RUN}" -iface hsn0 -bind-to core -launcher fork ./init_atmosphere_model

if [ -f "$INIT_FILE" ] && [ -s "$INIT_FILE" ]; then
    echo "--- SUCESSO: ${INIT_FILE} ---"
    ls -lh "$INIT_FILE"
    echo "Dimensões:"
    ncdump -h "$INIT_FILE" | grep -E "dimensions:|nCells|nVertLevels" | head -5
else
    echo "--- ERRO: ${INIT_FILE} não foi gerado ---"
    tail -20 log.init_atmosphere.0000.out 2>/dev/null
    exit 1
fi
