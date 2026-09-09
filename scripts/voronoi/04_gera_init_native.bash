#!/bin/bash
# ==============================================================================
# 04_gera_init_native.bash — Roda `gen_init_native` (Fases 2+3+4+6) pro tempo
# inicial e mescla com `ncks -A` os campos de copia direta do static.nc
# (geometria/malha/uso-do-solo), gerando o init.nc COMPLETO (135 variaveis,
# mesmo total do init.nc real de producao) -- sem chamar o
# init_atmosphere_model pra essa etapa.
#
# Pre-requisitos:
#   - <REGION_NAME>.static.nc (scripts/01_recorta_regiao.bash)
#   - namelist.init_atmosphere do init_run (config_start_time = INIT_TIME)
#   - native_target_<INIT_TIME>.nc (voronoi/03_interp_horizontal_nativa.bash)
#
# Precisa do NCO (`ncks`) no PATH -- normalmente ja disponivel em ambientes
# HPC de geociencias; se nao, `module load nco` ou equivalente antes de rodar.
# ==============================================================================

set -euo pipefail

DIR_VORONOI="${DIR_VORONOI:-/lustre/projetos/satdas/diego_workdir/SOURCE/voronoi_to_voronoi}"
DIR_MPAS2INTERMEDIATE="${DIR_MPAS2INTERMEDIATE:-${DIR_VORONOI}/mpas2intermediate}"

REGION_NAME="${REGION_NAME:-SouthAmerica}"
DIR_MALHA="${DIR_MALHA:-/lustre/projetos/satdas/diego_workdir/SOURCE/ungrib_to_mpas/recortes/${REGION_NAME}}"
STATIC_REGIONAL="${STATIC_REGIONAL:-${DIR_MALHA}/${REGION_NAME}.static.nc}"

FILE_BASE_INI="${FILE_BASE_INI:-/lustre/projetos/satdas/diego_workdir/SOURCE/FILE_BASE}"
NAMELIST_INIT="${NAMELIST_INIT:-${FILE_BASE_INI}/namelist.init_atmosphere}"

DIR_NATIVE="${DIR_NATIVE:-${DIR_MALHA}/native_intermediate}"
INIT_TIME="${INIT_TIME:-2026-01-01_00}"   # deve bater com config_start_time do NAMELIST_INIT

WORK_DIR="${WORK_DIR:-${DIR_MALHA}/init_run_native}"
INIT_FILE="${INIT_FILE:-${WORK_DIR}/${REGION_NAME}.init.nc}"

[ -x "${DIR_MPAS2INTERMEDIATE}/gen_init_native" ] || { echo "ERRO: gen_init_native não encontrado/executável em $DIR_MPAS2INTERMEDIATE (compile mpas2intermediate primeiro, 'make')"; exit 1; }
[ -f "$STATIC_REGIONAL" ] || { echo "ERRO: malha-alvo não encontrada: $STATIC_REGIONAL"; exit 1; }
[ -f "$NAMELIST_INIT" ]   || { echo "ERRO: namelist não encontrado: $NAMELIST_INIT"; exit 1; }
command -v ncks >/dev/null || { echo "ERRO: ncks (NCO) não encontrado no PATH -- 'module load nco' ou equivalente"; exit 1; }

NATIVE_TARGET="${DIR_NATIVE}/native_target_${INIT_TIME}.nc"
[ -f "$NATIVE_TARGET" ] || { echo "ERRO: $NATIVE_TARGET não encontrado (rode voronoi/03_interp_horizontal_nativa.bash primeiro)"; exit 1; }

echo "--- init.nc nativo (Fases 2+3+4+6 -- gen_init_native) [${REGION_NAME}] ---"
echo "  Malha-alvo   : ${STATIC_REGIONAL}"
echo "  Namelist     : ${NAMELIST_INIT}"
echo "  First-guess  : ${NATIVE_TARGET} (tempo ${INIT_TIME})"
echo "  Saída        : ${INIT_FILE}"

if [ -f "$INIT_FILE" ] && [ -s "$INIT_FILE" ] && ncdump -h "$INIT_FILE" &>/dev/null; then
    echo "Já existe e é válido: ${INIT_FILE} — nada a fazer."
    ls -lh "$INIT_FILE"
    exit 0
fi

mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

COMPUTED="${WORK_DIR}/computed_fields.nc"
echo "--- Passo 1/2: calculando campos (zgrid/zz/zb/zb3/qv/rho/theta/tmn/vegfra/...) ---"
"${DIR_MPAS2INTERMEDIATE}/gen_init_native" "$STATIC_REGIONAL" "$NAMELIST_INIT" "$NATIVE_TARGET" "$COMPUTED"

echo "--- Passo 2/2: mesclando com campos estáticos de $STATIC_REGIONAL (ncks -A) ---"
cp -f "$STATIC_REGIONAL" "$INIT_FILE"
ncks -A "$COMPUTED" "$INIT_FILE"

if [ -f "$INIT_FILE" ] && [ -s "$INIT_FILE" ]; then
    # Conta so' declaracoes de variavel (linha com "nome(dims)"), nao
    # atributos (que tambem terminam em ";" e batiam no grep antigo,
    # inflando a contagem -- achado 2026-09-09 numa rodada real no Jaci).
    n_vars=$(ncdump -h "$INIT_FILE" | sed -n '/^variables:/,/^$/p' | grep -cE '^[[:space:]]+[a-zA-Z_].*\([a-zA-Z_]' || true)
    echo "--- SUCESSO: ${INIT_FILE} (~${n_vars} variáveis) ---"
    ls -lh "$INIT_FILE"
else
    echo "--- ERRO: ${INIT_FILE} não foi gerado ---"
    exit 1
fi
