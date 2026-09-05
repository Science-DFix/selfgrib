#!/bin/bash
# ==============================================================================
# roda_pipeline_meteorologico.bash — Gera os arquivos meteorológicos
# intermediários (formato WPS) a partir de uma rodada global do MPAS-A já
# concluída, usando o pipeline selfgrib (extract_fields -> convert_mpas ->
# pack_intermediate), via mpas2intermediate/run_pipeline.sh.
#
# Não gera nada novo por interpolação de GRIB externo — lê os history.*.nc
# de uma rodada global que já rodou e virou (ela mesma) a fonte de dados.
# Ver mpas2intermediate/README.md para a arquitetura completa do pipeline.
#
# Variáveis de entrada/saída são todas configuráveis por ambiente (env vars).
# Os defaults abaixo apontam para o clone do selfgrib e para uma rodada
# global real já disponível no Jaci — sobrescreva via export para outra
# rodada/região/ambiente.
# ==============================================================================

set -euo pipefail

# --- Localização do clone do selfgrib e dos utilitários compilados ---
DIR_SELFGRIB="${DIR_SELFGRIB:-/lustre/projetos/satdas/diego_workdir/SOURCE/ungrib_to_mpas/selfgrib}"
DIR_MPAS2INTERMEDIATE="${DIR_MPAS2INTERMEDIATE:-${DIR_SELFGRIB}/mpas2intermediate}"
CONVERT_MPAS_BIN="${CONVERT_MPAS_BIN:-${DIR_SELFGRIB}/convert_mpas/convert_mpas}"

# --- Entrada: rodada global já concluída (contém history.*.nc) ---
DIR_RODADA_GLOBAL="${DIR_RODADA_GLOBAL:-/lustre/projetos/satdas/diego_workdir/SOURCE/dataout/PREV_MPAS/2026010100}"

# --- Saída ---
DIR_OUT="${DIR_OUT:-/lustre/projetos/satdas/diego_workdir/SOURCE/ungrib_to_mpas/recortes/SouthAmerica/met_intermediate}"
PREFIXO="${PREFIXO:-MPAS}"

# --- Grade lat-lon de remapeamento horizontal (convert_mpas), com margem
#     além da região realmente usada pela malha SouthAmerica recortada
#     (elipse: ~25.5N a ~-57.3S, ~-88W a ~-32W — ver South_America.ellipse.pts).
STARTLAT="${STARTLAT:--60.0}"
ENDLAT="${ENDLAT:-25.0}"
STARTLON="${STARTLON:--90.0}"
ENDLON="${ENDLON:--30.0}"
NLAT="${NLAT:-170}"
NLON="${NLON:-240}"

# --- Validações ---
[ -d "$DIR_RODADA_GLOBAL" ]     || { echo "ERRO: DIR_RODADA_GLOBAL não encontrado: $DIR_RODADA_GLOBAL"; exit 1; }
[ -x "${DIR_MPAS2INTERMEDIATE}/extract_fields" ]     || { echo "ERRO: extract_fields não encontrado/executável em $DIR_MPAS2INTERMEDIATE (compile mpas2intermediate primeiro)"; exit 1; }
[ -x "${DIR_MPAS2INTERMEDIATE}/pack_intermediate" ]  || { echo "ERRO: pack_intermediate não encontrado/executável em $DIR_MPAS2INTERMEDIATE (compile mpas2intermediate primeiro)"; exit 1; }
[ -x "$CONVERT_MPAS_BIN" ]                           || { echo "ERRO: convert_mpas não encontrado/executável em $CONVERT_MPAS_BIN (compile convert_mpas primeiro)"; exit 1; }

N_HISTORY=$(ls "${DIR_RODADA_GLOBAL}"/history.*.nc 2>/dev/null | wc -l)
[ "$N_HISTORY" -gt 0 ] || { echo "ERRO: nenhum history.*.nc encontrado em $DIR_RODADA_GLOBAL"; exit 1; }

echo "--- Pipeline meteorológico selfgrib ---"
echo "  Rodada global (fonte): ${DIR_RODADA_GLOBAL} (${N_HISTORY} arquivos history.*.nc)"
echo "  Saída                : ${DIR_OUT}"
echo "  Prefixo              : ${PREFIXO}"
echo "  Grade lat-lon        : lat [${STARTLAT}, ${ENDLAT}] lon [${STARTLON}, ${ENDLON}] (${NLAT}x${NLON})"

CONVERT_MPAS_BIN="$CONVERT_MPAS_BIN" \
    "${DIR_MPAS2INTERMEDIATE}/run_pipeline.sh" \
    "$DIR_RODADA_GLOBAL" "$DIR_OUT" "$PREFIXO" \
    "$STARTLAT" "$ENDLAT" "$STARTLON" "$ENDLON" "$NLAT" "$NLON"
