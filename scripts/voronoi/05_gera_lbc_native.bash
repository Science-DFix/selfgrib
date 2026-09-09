#!/bin/bash
# ==============================================================================
# 05_gera_lbc_native.bash — Roda `gen_lbc_native` (Fase 7 parcial) pra cada
# tempo em $TIMES, gerando lbc.<tempo>.00.00.nc -- reusa a malha vertical ja
# calculada no init.nc (passo 4), NAO recalcula.
#
# Pre-requisitos:
#   - init.nc completo (voronoi/04_gera_init_native.bash)
#   - namelist.init_atmosphere do lbc_run (config_blend_bdy_terrain=false)
#   - native_target_<tempo>.nc pra cada tempo (voronoi/03_interp_horizontal_nativa.bash)
#
# IMPORTANTE: config_start_time do NAMELIST_LBC e' FIXO (inicio de toda a
# janela do lbc_run, ex. sempre '2026-01-01_00:00:00'), NAO o tempo de cada
# arquivo individual -- por isso o tempo-alvo de cada arquivo e' passado
# como argumento separado pro gen_lbc_native (ver plano, secao Fase 7).
# ==============================================================================

set -euo pipefail

DIR_VORONOI="${DIR_VORONOI:-/lustre/projetos/satdas/diego_workdir/SOURCE/voronoi_to_voronoi}"
DIR_MPAS2INTERMEDIATE="${DIR_MPAS2INTERMEDIATE:-${DIR_VORONOI}/mpas2intermediate}"

REGION_NAME="${REGION_NAME:-SouthAmerica}"
DIR_MALHA="${DIR_MALHA:-/lustre/projetos/satdas/diego_workdir/SOURCE/ungrib_to_mpas/recortes/${REGION_NAME}}"

FILE_BASE_INI="${FILE_BASE_INI:-/lustre/projetos/satdas/diego_workdir/SOURCE/FILE_BASE}"
NAMELIST_LBC="${NAMELIST_LBC:-${FILE_BASE_INI}/namelist.init_atmosphere}"   # idealmente o do lbc_run (config_blend_bdy_terrain=false)

DIR_NATIVE="${DIR_NATIVE:-${DIR_MALHA}/native_intermediate}"
INIT_FILE="${INIT_FILE:-${DIR_MALHA}/init_run_native/${REGION_NAME}.init.nc}"

WORK_DIR="${WORK_DIR:-${DIR_MALHA}/lbc_run_native}"

# Todos os tempos a gerar lbc.*.nc (tipicamente $TIMES inteiro, incluindo o
# tempo inicial -- o lbc_run real de producao tambem gera um lbc.nc pro
# tempo 0, ver README).
TIMES="${TIMES:-2026-01-01_00 2026-01-01_06 2026-01-01_12 2026-01-01_18 2026-01-02_00}"

[ -x "${DIR_MPAS2INTERMEDIATE}/gen_lbc_native" ] || { echo "ERRO: gen_lbc_native não encontrado/executável em $DIR_MPAS2INTERMEDIATE (compile mpas2intermediate primeiro, 'make')"; exit 1; }
[ -f "$INIT_FILE" ]    || { echo "ERRO: init.nc não encontrado: $INIT_FILE (rode voronoi/04_gera_init_native.bash primeiro)"; exit 1; }
[ -f "$NAMELIST_LBC" ] || { echo "ERRO: namelist não encontrado: $NAMELIST_LBC"; exit 1; }

mkdir -p "$WORK_DIR"

echo "--- lbc.*.nc nativo (Fase 7 parcial -- gen_lbc_native) [${REGION_NAME}] ---"
echo "  init.nc (malha vertical) : ${INIT_FILE}"
echo "  Namelist                 : ${NAMELIST_LBC}"
echo "  Tempos                   : ${TIMES}"
echo "  Saída                    : ${WORK_DIR}/lbc.<tempo>.00.00.nc"

n_ok=0; n_skip=0; n_fail=0
for hdate in $TIMES; do
    native_target="${DIR_NATIVE}/native_target_${hdate}.nc"
    valid_time="${hdate}:00:00"
    out="${WORK_DIR}/lbc.${hdate}.00.00.nc"

    if [ ! -f "$native_target" ]; then
        echo "[FAIL] ${hdate} -- ${native_target} não encontrado (rode 03_interp_horizontal_nativa.bash primeiro)"
        n_fail=$((n_fail+1))
        continue
    fi

    if [ -f "$out" ] && [ -s "$out" ]; then
        echo "[SKIP] ${hdate} -- ${out} já existe"
        n_skip=$((n_skip+1))
        continue
    fi

    echo "[RUN ] ${hdate}"
    t0=$(date +%s)
    if ! "${DIR_MPAS2INTERMEDIATE}/gen_lbc_native" \
            "$INIT_FILE" "$NAMELIST_LBC" "$native_target" "$out" "$valid_time" \
            > "${WORK_DIR}/log_lbc_${hdate}.log" 2>&1; then
        echo "[FAIL] ${hdate} -- gen_lbc_native (veja ${WORK_DIR}/log_lbc_${hdate}.log)"
        n_fail=$((n_fail+1))
        continue
    fi
    t1=$(date +%s)
    echo "[ OK ] ${hdate} -- $(basename "$out") ($((t1-t0))s)"
    n_ok=$((n_ok+1))
done

echo ""
echo "===================================================="
echo "OK=$n_ok  SKIP=$n_skip  FAIL=$n_fail"
echo "Saída em: $WORK_DIR"
echo "===================================================="
[ "$n_fail" -eq 0 ]
