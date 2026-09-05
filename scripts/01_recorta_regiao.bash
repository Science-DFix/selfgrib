#!/bin/bash
# ==============================================================================
# 01_recorta_regiao.bash — Recorta uma malha regional a partir da malha global
# do MPAS-A, reaproveitando o static.nc global (terreno, uso do solo,
# climatologia de vegetação/albedo) via MPAS-Limited-Area (create_region).
#
# NÃO interpola nada novo do WPS_GEOG — apenas recorta os campos estáticos
# já existentes no static.nc de entrada para a subregião definida no .pts.
# Ver MPAS-Limited-Area/HOWTO_RECORTE.md para o racional completo.
#
# Variáveis de entrada/saída são todas configuráveis por ambiente (env vars).
# Os defaults abaixo apontam para o clone do selfgrib no Jaci — sobrescreva
# via export se rodar o script de outro lugar (não dependem de onde este
# arquivo físico está salvo).
# ==============================================================================

set -euo pipefail

# --- Localização do clone do selfgrib (para os defaults abaixo) ---
DIR_SELFGRIB="${DIR_SELFGRIB:-/lustre/projetos/satdas/diego_workdir/SOURCE/ungrib_to_mpas/selfgrib}"
DIR_LIMITED_AREA="${DIR_LIMITED_AREA:-${DIR_SELFGRIB}/MPAS-Limited-Area}"
PYTHON_BIN="${PYTHON_BIN:-python3}"

# --- Entrada ---
STATIC_GLOBAL="${STATIC_GLOBAL:-/lustre/projetos/satdas/diego_workdir/SOURCE/FILE_BASE/60km/x1.163842.static.nc}"
PTS_FILE="${PTS_FILE:-${DIR_LIMITED_AREA}/South_America.ellipse.pts}"

# --- Saída ---
DIR_OUT="${DIR_OUT:-/lustre/projetos/satdas/diego_workdir/SOURCE/ungrib_to_mpas/recortes/SouthAmerica}"
NP_PARTS="${NP_PARTS:-32 64 128 256}"   # lista de particoes MPI (gpmetis), separadas por espaço; vazio ("") desliga o particionamento
METIS_MODULE="${METIS_MODULE:-metis/5.1.0}"   # modulo a carregar se gpmetis nao estiver no PATH (module load); vazio ("") nao tenta carregar

# --- Validações ---
[ -f "$STATIC_GLOBAL" ] || { echo "ERRO: STATIC_GLOBAL não encontrado: $STATIC_GLOBAL"; exit 1; }
[ -f "$PTS_FILE" ]      || { echo "ERRO: PTS_FILE não encontrado: $PTS_FILE"; exit 1; }
command -v "$PYTHON_BIN" >/dev/null || { echo "ERRO: $PYTHON_BIN não encontrado no PATH"; exit 1; }

REGION_NAME=$(grep -m1 -i '^Name:' "$PTS_FILE" | sed -E 's/^Name:[[:space:]]*//')
[ -n "$REGION_NAME" ] || { echo "ERRO: não encontrei a chave 'Name:' em $PTS_FILE"; exit 1; }

mkdir -p "$DIR_OUT"

OUT_STATIC="${DIR_OUT}/${REGION_NAME}.static.nc"
OUT_GRAPH="${DIR_OUT}/${REGION_NAME}.graph.info"

echo "--- Recorte de região: ${REGION_NAME} ---"
echo "  Malha global : ${STATIC_GLOBAL}"
echo "  Pontos (.pts): ${PTS_FILE}"
echo "  Saída        : ${DIR_OUT}"

if [ -f "$OUT_STATIC" ] && [ -s "$OUT_STATIC" ]; then
    echo "Já existe: ${OUT_STATIC} — pulando recorte."
else
    (
        cd "$DIR_OUT"
        "$PYTHON_BIN" "${DIR_LIMITED_AREA}/create_region" -v 2 "$PTS_FILE" "$STATIC_GLOBAL"
    )
fi

[ -f "$OUT_STATIC" ] && [ -s "$OUT_STATIC" ] || { echo "ERRO: recorte não gerou ${OUT_STATIC}"; exit 1; }
[ -f "$OUT_GRAPH" ]  && [ -s "$OUT_GRAPH" ]  || { echo "ERRO: recorte não gerou ${OUT_GRAPH}"; exit 1; }

echo "OK: ${OUT_STATIC}"
echo "OK: ${OUT_GRAPH}"

# --- Particionamento opcional (gpmetis), para rodar com N tarefas MPI ---
if [ -n "$NP_PARTS" ]; then
    if ! command -v gpmetis >/dev/null && [ -n "$METIS_MODULE" ] && command -v module >/dev/null; then
        echo "gpmetis não está no PATH — tentando 'module load ${METIS_MODULE}'..."
        module load "$METIS_MODULE"
    fi
    command -v gpmetis >/dev/null || { echo "ERRO: gpmetis não encontrado no PATH (defina METIS_MODULE ou carregue o modulo manualmente antes de rodar)"; exit 1; }

    for N in $NP_PARTS; do
        OUT_PART="${OUT_GRAPH}.part.${N}"
        if [ -f "$OUT_PART" ]; then
            echo "Já existe: ${OUT_PART} — pulando particionamento."
        else
            echo "--- Particionando ${OUT_GRAPH} para ${N} tarefas MPI ---"
            gpmetis -minconn -contig -niter=200 "$OUT_GRAPH" "$N"
        fi
        echo "OK: ${OUT_PART}"
    done
fi
