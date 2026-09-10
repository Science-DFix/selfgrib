#!/bin/bash
# ==============================================================================
# 02_extrai_first_guess.bash — Roda `extract_fields` em cada history.*.nc da
# rodada global do MPAS-A que cobre os tempos necessarios (init + cada tempo
# de fronteira lateral), gerando um extracted_<tempo>.nc por tempo (ainda na
# malha nativa GLOBAL, niveis de pressao fixos -- ver
# core/src/pressure_levels.F90).
#
# Equivalente ao primeiro sub-passo do run_pipeline.sh da rota de producao
# (core/pipeline/legacy/02_roda_pipeline_meteorologico.bash), mas SEM convert_mpas/grade
# lat-lon -- essa rota faz a interpolacao horizontal depois, direto na malha
# nativa (03_interp_horizontal_nativa.bash).
#
# Pre-requisitos: nenhum (so' precisa da rodada global + core/src
# ja compilado).
# ==============================================================================

set -euo pipefail

DIR_VORONOI="${DIR_VORONOI:-/lustre/projetos/satdas/diego_workdir/SOURCE/voronoi_to_voronoi}"
DIR_MPAS2INTERMEDIATE="${DIR_MPAS2INTERMEDIATE:-${DIR_VORONOI}/core/src}"

DIR_RODADA_GLOBAL="${DIR_RODADA_GLOBAL:-/lustre/projetos/satdas/diego_workdir/SOURCE/dataout/PREV_MPAS/2026010100}"

REGION_NAME="${REGION_NAME:-SouthAmerica}"
DIR_MALHA="${DIR_MALHA:-/lustre/projetos/satdas/diego_workdir/SOURCE/ungrib_to_mpas/recortes/${REGION_NAME}}"
DIR_OUT="${DIR_OUT:-${DIR_MALHA}/native_intermediate}"

# Tempos a processar (AAAA-MM-DD_HH, separados por espaco) -- precisa
# cobrir o tempo inicial (init.nc) + todos os tempos de fronteira (lbc.*.nc).
TIMES="${TIMES:-2026-01-01_00 2026-01-01_06 2026-01-01_12 2026-01-01_18 2026-01-02_00}"

[ -x "${DIR_MPAS2INTERMEDIATE}/extract_fields" ] || { echo "ERRO: extract_fields não encontrado/executável em $DIR_MPAS2INTERMEDIATE (compile core/src primeiro, 'make')"; exit 1; }
[ -d "$DIR_RODADA_GLOBAL" ] || { echo "ERRO: DIR_RODADA_GLOBAL não encontrado: $DIR_RODADA_GLOBAL"; exit 1; }

mkdir -p "$DIR_OUT"

echo "--- Extraindo first-guess (Fase 0 -- extract_fields) ---"
echo "  Rodada global: ${DIR_RODADA_GLOBAL}"
echo "  Tempos       : ${TIMES}"
echo "  Saída        : ${DIR_OUT}"

n_ok=0; n_skip=0; n_fail=0
for hdate in $TIMES; do
    src="${DIR_RODADA_GLOBAL}/history.${hdate}.00.00.nc"
    out="${DIR_OUT}/extracted_${hdate}.nc"

    if [ ! -f "$src" ]; then
        echo "[FAIL] ${hdate} -- fonte não encontrada: ${src}"
        n_fail=$((n_fail+1))
        continue
    fi

    if [ -f "$out" ] && [ -s "$out" ]; then
        echo "[SKIP] ${hdate} -- ${out} já existe"
        n_skip=$((n_skip+1))
        continue
    fi

    echo "[RUN ] ${hdate} -- fonte: $(basename "$src")"
    t0=$(date +%s)
    if ! "${DIR_MPAS2INTERMEDIATE}/extract_fields" "$src" "$out" > "${DIR_OUT}/log_extract_${hdate}.log" 2>&1; then
        echo "[FAIL] ${hdate} -- extract_fields (veja ${DIR_OUT}/log_extract_${hdate}.log)"
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
echo "Saída em: $DIR_OUT"
echo "===================================================="
[ "$n_fail" -eq 0 ]
