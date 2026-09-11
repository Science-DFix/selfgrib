#!/bin/bash
# ==============================================================================
# master_voronoi_regional.bash — Roda o pipeline nativo Voronoi (selfgrib,
# core/pipeline/native/0{1..6}_*.bash) usando como first-guess a previsão
# GLOBAL de 15km gerada em rodada_global_15km/forecast/2026013100 (em vez do
# GFS/WPS), pra recortar e prever a regiao SouthAmerica.
#
# Pre-requisito: core/src (e core/vendor/convert_mpas) ja compilados --
# ver instrucoes de compilacao separadas antes de rodar este script.
#
# Tudo (malha regional recortada, intermediarios, init/lbc/forecast) fica
# dentro de rodada_global_15km/, nada em ungrib_to_mpas/recortes/.
#
# ACOMPANHAMENTO: master.log cresce em tempo real (tee -a, sem buffering --
# todo mundo aqui usa 'echo'/linhas completas). status_atual.txt sempre tem
# so' a etapa em andamento, pra checar rapido sem escanear o log inteiro.
#   tail -f /lustre/.../rodada_global_15km/master.log
#   cat  /lustre/.../rodada_global_15km/status_atual.txt
# ==============================================================================

set -euo pipefail

# Ajuste DIR_ROOT/DIR_BASE para o seu ambiente
DIR_ROOT="${DIR_ROOT:-/lustre/projetos/satdas/diego_workdir}"
DIR_BASE="${DIR_BASE:-${DIR_ROOT}/SOURCE/rodada_global_15km}"
export DIR_VORONOI="${DIR_VORONOI:-${DIR_BASE}/selfgrib}"

LOG="${DIR_BASE}/master.log"
STATUS="${DIR_BASE}/status_atual.txt"

log_step() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg" | tee -a "$LOG"
    echo "$msg" > "$STATUS"
}

# --- Fonte: previsao global 15km ja gerada (Etapa 1 deste experimento) ---
export DIR_RODADA_GLOBAL="${DIR_RODADA_GLOBAL:-${DIR_BASE}/forecast/2026013100}"

# --- Regiao ---
export REGION_NAME="${REGION_NAME:-SouthAmerica}"
export DIR_MALHA="${DIR_MALHA:-${DIR_BASE}/recorte_${REGION_NAME}}"

# --- Tempos disponiveis na previsao global 15km (history a cada 6h --
#     ver bug do sed do output_interval corrigido depois; esta rodada ja
#     saiu assim, e por acaso e exatamente o intervalo que o LBC precisa) ---
export TIMES="${TIMES:-2026-01-31_00 2026-01-31_06 2026-01-31_12 2026-01-31_18 2026-02-01_00}"
INIT_TIME="${INIT_TIME:-2026-01-31_00}"

# --- Passo 1: recorte da regiao a partir da malha GLOBAL 15km (nao 60km) ---
# DIR_OUT NAO e exportado globalmente aqui de proposito: 02_extrai_first_guess.bash
# e 03_interp_horizontal_nativa.bash tambem leem uma variavel DIR_OUT (default
# ${DIR_MALHA}/native_intermediate) -- exportar globalmente vazava esse valor
# pros passos seguintes, fazendo o 02 escrever direto em DIR_MALHA em vez de
# DIR_MALHA/native_intermediate (achado numa rodada real, corrigido).
export DIR_SELFGRIB="${DIR_SELFGRIB:-${DIR_VORONOI}}"
export STATIC_GLOBAL="${STATIC_GLOBAL:-${DIR_BASE}/static/x1.2621442.static.nc}"
export PTS_FILE="${PTS_FILE:-${DIR_VORONOI}/core/vendor/limited_area/South_America.ellipse.pts}"
DIR_OUT_RECORTE="${DIR_MALHA}"
export NP_PARTS="32 64 128 256"
export METIS_MODULE="${METIS_MODULE:-metis/5.1.0}"

# --- Namelists reais (config_start_time ajustado, blend_bdy_terrain
#     true/false -- ver rodada_global_15km/recorte_SouthAmerica/namelist_*) ---
export NAMELIST_INIT="${DIR_MALHA}/namelist_init_native.init_atmosphere"
export NAMELIST_LBC="${DIR_MALHA}/namelist_lbc_native.init_atmosphere"
export INIT_TIME

# --- Passo 6: previsao regional de verdade ---
export FILE_BASE_ATM="${DIR_BASE}/FILE_BASE_15km/core_atmosphere"   # dt=90/len_disp=15000 (malha 15km!), nao o FILE_BASE de 60km
export START_TIME="${INIT_TIME}:00:00"   # INIT_TIME ja inclui a hora (ex: 2026-01-31_00); so falta :00:00 (min:seg). BUG anterior: "${INIT_TIME}_00:00:00" duplicava a hora ("..._00_00:00:00"), causando "ERROR: Invalid DateTime string" e SIGSEGV em todos os 256 ranks.
export RUN_DURATION="1_00:00:00"          # 24h
export OUTPUT_INTERVAL="03:00:00"
export DIAG_INTERVAL="03:00:00"
export DT="90"                             # mesma regra 6*dx_km da malha 15km
export RADT_INTERVAL="00:30:00"
export NP_RUN="256"
export LBC_INPUT_INTERVAL="6:00:00"        # bate com o intervalo real de TIMES

: > "$LOG"
echo "======================================================" | tee -a "$LOG"
echo " Voronoi-to-Voronoi regional: ${REGION_NAME}"            | tee -a "$LOG"
echo " Fonte global    : ${DIR_RODADA_GLOBAL}"                  | tee -a "$LOG"
echo " Malha regional  : ${DIR_MALHA}"                          | tee -a "$LOG"
echo " NP (previsao)   : ${NP_RUN}"                             | tee -a "$LOG"
echo " Iniciado        : $(date)"                                | tee -a "$LOG"
echo " Acompanhe com   : tail -f ${LOG}"                          | tee -a "$LOG"
echo "======================================================" | tee -a "$LOG"

cd "$DIR_VORONOI"

log_step "--- [1/6] INICIO -- Recorte da regiao (malha global 15km) ---"
t0=$(date +%s)
DIR_OUT="${DIR_OUT_RECORTE}" bash core/pipeline/01_recorta_regiao.bash 2>&1 | tee -a "$LOG"
log_step "--- [1/6] FIM ($(( $(date +%s) - t0 ))s) ---"

log_step "--- [2/6] INICIO -- Extrai first-guess (history.*.nc da previsao 15km) ---"
t0=$(date +%s)
bash core/pipeline/native/02_extrai_first_guess.bash 2>&1 | tee -a "$LOG"
log_step "--- [2/6] FIM ($(( $(date +%s) - t0 ))s) ---"

log_step "--- [3/6] INICIO -- Interpolacao horizontal nativa (baricentrica) ---"
t0=$(date +%s)
bash core/pipeline/native/03_interp_horizontal_nativa.bash 2>&1 | tee -a "$LOG"
log_step "--- [3/6] FIM ($(( $(date +%s) - t0 ))s) ---"

log_step "--- [4/6] INICIO -- Gera init.nc nativo ---"
t0=$(date +%s)
bash core/pipeline/native/04_gera_init_native.bash 2>&1 | tee -a "$LOG"
log_step "--- [4/6] FIM ($(( $(date +%s) - t0 ))s) ---"

log_step "--- [5/6] INICIO -- Gera lbc.*.nc nativo ---"
t0=$(date +%s)
bash core/pipeline/native/05_gera_lbc_native.bash 2>&1 | tee -a "$LOG"
log_step "--- [5/6] FIM ($(( $(date +%s) - t0 ))s) ---"

log_step "--- [6/6] INICIO -- Roda mpas_atmosphere (previsao regional de 24h) ---"
t0=$(date +%s)
bash core/pipeline/native/06_roda_previsao_native.bash 2>&1 | tee -a "$LOG"
log_step "--- [6/6] FIM ($(( $(date +%s) - t0 ))s) ---"

log_step "=== PIPELINE CONCLUIDO COM SUCESSO ==="
