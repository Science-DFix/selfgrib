#!/bin/bash
# ==============================================================================
# master_voronoi_regional_60km.bash — Mesma rota nativa Voronoi-to-Voronoi
# (core/pipeline/native/0{2..6}_*.bash) do master_voronoi_regional.bash, mas
# usando a rodada global de PRODUCAO em 60km (x1.163842) ja existente em
# dataout/PREV_MPAS/2026013100 como first-guess, para a MESMA data da rodada
# de 15km (2026-01-31_00 + 24h) -- permite comparacao direta 60km vs 15km no
# mesmo dia, em vez do caso original (2026-01-01) documentado no README.
#
# Passo 1 (recorte) NAO e' rodado aqui: reusa o recorte SouthAmerica.static.nc
# / .graph.info.part.* ja existentes (mesma geometria regional, independente
# da data), copiados para recorte_SouthAmerica_60km/ antes de este script
# rodar -- evita colidir com os arquivos do caso original (2026-01-01) que
# ja estao documentados no README principal.
# ==============================================================================

set -euo pipefail

DIR_ROOT="${DIR_ROOT:-/lustre/projetos/satdas/diego_workdir}"
DIR_BASE="${DIR_BASE:-${DIR_ROOT}/SOURCE/rodada_global_15km}"
export DIR_VORONOI="${DIR_VORONOI:-${DIR_BASE}/selfgrib}"

LOG="${DIR_BASE}/master_60km.log"
STATUS="${DIR_BASE}/status_atual_60km.txt"

log_step() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg" | tee -a "$LOG"
    echo "$msg" > "$STATUS"
}

# --- Fonte: rodada global de PRODUCAO 60km, mesma data da rodada 15km ---
export DIR_RODADA_GLOBAL="${DIR_RODADA_GLOBAL:-${DIR_ROOT}/SOURCE/dataout/PREV_MPAS/2026013100}"

# --- Regiao: reusa o recorte 60km ja existente (copiado antes p/ este dir) ---
export REGION_NAME="${REGION_NAME:-SouthAmerica}"
export DIR_MALHA="${DIR_MALHA:-${DIR_BASE}/recorte_${REGION_NAME}_60km}"

# --- Tempos: history de producao 60km tambem sai a cada 6h ---
export TIMES="${TIMES:-2026-01-31_00 2026-01-31_06 2026-01-31_12 2026-01-31_18 2026-02-01_00}"
INIT_TIME="${INIT_TIME:-2026-01-31_00}"

# --- Namelists reais (mesmos da rodada 15km -- mesma regiao/parametros fisicos) ---
export NAMELIST_INIT="${DIR_MALHA}/namelist_init_native.init_atmosphere"
export NAMELIST_LBC="${DIR_MALHA}/namelist_lbc_native.init_atmosphere"
export INIT_TIME

# --- Passo 6: previsao regional de verdade, template ORIGINAL de 60km ---
export FILE_BASE_ATM="${DIR_ROOT}/SOURCE/FILE_BASE/core_atmosphere"   # dt=360/len_disp=60000, malha 60km
export START_TIME="${INIT_TIME}:00:00"
export RUN_DURATION="1_00:00:00"          # 24h
export OUTPUT_INTERVAL="03:00:00"
export DIAG_INTERVAL="03:00:00"
export DT="360"                            # regra 6*dx_km da malha 60km
export RADT_INTERVAL="00:30:00"
export NP_RUN="32"                         # mesmo NP do caso original documentado
export LBC_INPUT_INTERVAL="6:00:00"

: > "$LOG"
echo "======================================================" | tee -a "$LOG"
echo " Voronoi-to-Voronoi regional (60km): ${REGION_NAME}"     | tee -a "$LOG"
echo " Fonte global    : ${DIR_RODADA_GLOBAL}"                  | tee -a "$LOG"
echo " Malha regional  : ${DIR_MALHA}"                          | tee -a "$LOG"
echo " NP (previsao)   : ${NP_RUN}"                             | tee -a "$LOG"
echo " Iniciado        : $(date)"                                | tee -a "$LOG"
echo " Acompanhe com   : tail -f ${LOG}"                          | tee -a "$LOG"
echo "======================================================" | tee -a "$LOG"

cd "$DIR_VORONOI"

log_step "--- [2/5] INICIO -- Extrai first-guess (history.*.nc 60km producao) ---"
t0=$(date +%s)
bash core/pipeline/native/02_extrai_first_guess.bash 2>&1 | tee -a "$LOG"
log_step "--- [2/5] FIM ($(( $(date +%s) - t0 ))s) ---"

log_step "--- [3/5] INICIO -- Interpolacao horizontal nativa (baricentrica) ---"
t0=$(date +%s)
bash core/pipeline/native/03_interp_horizontal_nativa.bash 2>&1 | tee -a "$LOG"
log_step "--- [3/5] FIM ($(( $(date +%s) - t0 ))s) ---"

log_step "--- [4/5] INICIO -- Gera init.nc nativo ---"
t0=$(date +%s)
bash core/pipeline/native/04_gera_init_native.bash 2>&1 | tee -a "$LOG"
log_step "--- [4/5] FIM ($(( $(date +%s) - t0 ))s) ---"

log_step "--- [5/5a] INICIO -- Gera lbc.*.nc nativo ---"
t0=$(date +%s)
bash core/pipeline/native/05_gera_lbc_native.bash 2>&1 | tee -a "$LOG"
log_step "--- [5/5a] FIM ($(( $(date +%s) - t0 ))s) ---"

log_step "--- [5/5b] INICIO -- Roda mpas_atmosphere (previsao regional 60km, 24h) ---"
t0=$(date +%s)
bash core/pipeline/native/06_roda_previsao_native.bash 2>&1 | tee -a "$LOG"
log_step "--- [5/5b] FIM ($(( $(date +%s) - t0 ))s) ---"

log_step "=== PIPELINE 60km CONCLUIDO COM SUCESSO ==="
