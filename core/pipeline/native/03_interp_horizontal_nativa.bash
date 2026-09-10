#!/bin/bash
# ==============================================================================
# 03_interp_horizontal_nativa.bash — Roda `hinterp_native` (Fase 1) pra cada
# tempo extraido pelo passo 2: remapeia os campos direto da malha nativa
# GLOBAL pros centros de celula da malha-alvo (REGION_NAME.static.nc),
# interpolacao baricentrica na malha dual de Delaunay -- sem grade lat-lon
# intermediaria.
#
# Pre-requisitos:
#   - <REGION_NAME>.static.nc (core/pipeline/01_recorta_regiao.bash)
#   - extracted_<tempo>.nc pra cada tempo (voronoi/02_extrai_first_guess.bash)
# ==============================================================================

set -euo pipefail

DIR_VORONOI="${DIR_VORONOI:-/lustre/projetos/satdas/diego_workdir/SOURCE/voronoi_to_voronoi}"
DIR_MPAS2INTERMEDIATE="${DIR_MPAS2INTERMEDIATE:-${DIR_VORONOI}/core/src}"

DIR_RODADA_GLOBAL="${DIR_RODADA_GLOBAL:-/lustre/projetos/satdas/diego_workdir/SOURCE/dataout/PREV_MPAS/2026010100}"

REGION_NAME="${REGION_NAME:-SouthAmerica}"
DIR_MALHA="${DIR_MALHA:-/lustre/projetos/satdas/diego_workdir/SOURCE/ungrib_to_mpas/recortes/${REGION_NAME}}"
STATIC_REGIONAL="${STATIC_REGIONAL:-${DIR_MALHA}/${REGION_NAME}.static.nc}"

DIR_EXTRACTED="${DIR_EXTRACTED:-${DIR_MALHA}/native_intermediate}"
DIR_OUT="${DIR_OUT:-${DIR_MALHA}/native_intermediate}"

TIMES="${TIMES:-2026-01-01_00 2026-01-01_06 2026-01-01_12 2026-01-01_18 2026-01-02_00}"

[ -x "${DIR_MPAS2INTERMEDIATE}/hinterp_native" ] || { echo "ERRO: hinterp_native não encontrado/executável em $DIR_MPAS2INTERMEDIATE (compile core/src primeiro, 'make')"; exit 1; }
[ -f "$STATIC_REGIONAL" ] || { echo "ERRO: malha-alvo não encontrada: $STATIC_REGIONAL (rode core/pipeline/01_recorta_regiao.bash primeiro)"; exit 1; }

mkdir -p "$DIR_OUT"

echo "--- Interpolação horizontal nativa (Fase 1 -- hinterp_native) ---"
echo "  Malha-alvo        : ${STATIC_REGIONAL}"
echo "  Malha de origem   : rodada global em ${DIR_RODADA_GLOBAL} (conectividade)"
echo "  Tempos            : ${TIMES}"
echo "  Saída             : ${DIR_OUT}/native_target_<tempo>.nc"

n_ok=0; n_skip=0; n_fail=0
for hdate in $TIMES; do
    src_mesh="${DIR_RODADA_GLOBAL}/history.${hdate}.00.00.nc"
    extracted="${DIR_EXTRACTED}/extracted_${hdate}.nc"
    out="${DIR_OUT}/native_target_${hdate}.nc"

    if [ ! -f "$extracted" ]; then
        echo "[FAIL] ${hdate} -- extracted não encontrado: ${extracted} (rode 02_extrai_first_guess.bash primeiro)"
        n_fail=$((n_fail+1))
        continue
    fi
    if [ ! -f "$src_mesh" ]; then
        echo "[FAIL] ${hdate} -- malha de origem não encontrada: ${src_mesh}"
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
    # hinterp_native tem saida fixa 'native_target.nc' no diretorio corrente
    # (mesma convencao do convert_mpas/latlon.nc) -- roda num subdiretorio
    # temporario pra nao colidir entre tempos, depois move/renomeia.
    tmpdir=$(mktemp -d "${DIR_OUT}/.tmp_hinterp_${hdate}.XXXXXX")
    if ! ( cd "$tmpdir" && "${DIR_MPAS2INTERMEDIATE}/hinterp_native" \
             "$STATIC_REGIONAL" "$src_mesh" "$extracted" \
             > "${DIR_OUT}/log_hinterp_${hdate}.log" 2>&1 ); then
        echo "[FAIL] ${hdate} -- hinterp_native (veja ${DIR_OUT}/log_hinterp_${hdate}.log)"
        rm -rf "$tmpdir"
        n_fail=$((n_fail+1))
        continue
    fi
    mv -f "${tmpdir}/native_target.nc" "$out"
    rm -rf "$tmpdir"
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
