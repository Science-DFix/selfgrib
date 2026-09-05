#!/bin/bash
# ==============================================================================
# 04_gera_lbc.bash — Roda o init_atmosphere_model com config_init_case=9
# para gerar os arquivos de condição de contorno lateral (lbc.*.nc) da
# malha regional recortada, usando os MESMOS arquivos meteorológicos
# intermediários (MPAS:*) do pipeline selfgrib.
#
# Procedimento oficial (NCAR, tutorial "Regional MPAS", docs/regional_mpas_edi.pdf,
# slides 19-20 e 24): gerar LBC é o MESMO executável mpas_init_atmosphere
# usado para o init.nc (03_roda_init_atmosphere.bash), só que com
# config_init_case=9 em vez de 7, e um streams.init_atmosphere diferente:
#   - stream "input": aponta para o <REGION_NAME>.init.nc (nao mais o
#     static.nc) -- fornece a informacao de malha vertical ja calculada.
#   - stream "lbc" (novo, output): gera lbc.$Y-$M-$D_$h.nc a cada
#     config_fg_interval segundos, cobrindo config_start_time ate
#     config_stop_time.
#
# Pré-requisitos (produzidos pelas etapas anteriores):
#   - <REGION_NAME>.init.nc (ver scripts/03_roda_init_atmosphere.bash)
#   - <PREFIXO>:AAAA-MM-DD_HH em DIR_MET, cobrindo todo o periodo LBC_START..LBC_STOP
#     (ver scripts/02_roda_pipeline_meteorologico.bash)
#
# Variáveis de entrada/saída são todas configuráveis por ambiente (env vars).
# ==============================================================================

set -euo pipefail

# --- Ambiente do cluster (módulos, MPI, NetCDF) ---
ENV_ALL="${ENV_ALL:-/lustre/projetos/satdas/diego_workdir/env_wrf_wps.bash}"
[ -f "$ENV_ALL" ] && source "$ENV_ALL"

# --- Templates de namelist/streams (mesmos usados em produção para o init) ---
FILE_BASE_INI="${FILE_BASE_INI:-/lustre/projetos/satdas/diego_workdir/SOURCE/FILE_BASE}"

# --- Malha regional recortada (ver scripts/01_recorta_regiao.bash) ---
DIR_MALHA="${DIR_MALHA:-/lustre/projetos/satdas/diego_workdir/SOURCE/ungrib_to_mpas/recortes/SouthAmerica}"
REGION_NAME="${REGION_NAME:-SouthAmerica}"

# --- init.nc ja gerado (fornece a malha vertical para o LBC) ---
INIT_FILE="${INIT_FILE:-${DIR_MALHA}/init_run/${REGION_NAME}.init.nc}"

# --- Arquivos meteorológicos intermediários (ver scripts/02_roda_pipeline_meteorologico.bash) ---
DIR_MET="${DIR_MET:-${DIR_MALHA}/met_intermediate}"
PREFIXO="${PREFIXO:-MPAS}"

# --- Executável do init_atmosphere_model (mesmo build do 03_, single precision) ---
DIR_EXE="${DIR_EXE:-/lustre/projetos/satdas/diego_workdir/build-mpich-single/bin}"

# --- Período do LBC: precisa cobrir do inicio ao fim da previsão desejada
#     (05_roda_previsao.bash), e estar dentro do periodo com MPAS:* gerado. ---
LBC_START_TIME="${LBC_START_TIME:-2026-01-01_00:00:00}"
LBC_STOP_TIME="${LBC_STOP_TIME:-2026-01-02_00:00:00}"

# --- Intervalo entre os arquivos MPAS:* (em segundos) -- precisa bater
#     EXATAMENTE com o "filename_interval"/output_interval do stream lbc_in
#     em 05_roda_previsao.bash, senao o mpas_atmosphere trava com
#     "Failed to process LBC data at next time after ...". Nossos MPAS:*
#     sao gerados de 6 em 6h por 02_roda_pipeline_meteorologico.bash. ---
FG_INTERVAL_SEC="${FG_INTERVAL_SEC:-21600}"
LBC_INTERVAL_HHMMSS="${LBC_INTERVAL_HHMMSS:-6:00:00}"

N_FGLEVELS="${N_FGLEVELS:-62}"     # mesmo valor de 03_roda_init_atmosphere.bash
NP_RUN="${NP_RUN:-32}"

# --- Diretório de trabalho da rodada ---
WORK_DIR="${WORK_DIR:-${DIR_MALHA}/lbc_run}"

# --- Validações ---
GRAPH_PART="${DIR_MALHA}/${REGION_NAME}.graph.info.part.${NP_RUN}"
[ -f "$INIT_FILE" ]  || { echo "ERRO: init.nc não encontrado: $INIT_FILE (rode 03_roda_init_atmosphere.bash primeiro)"; exit 1; }
[ -f "$GRAPH_PART" ] || { echo "ERRO: graph.info particionado não encontrado: $GRAPH_PART"; exit 1; }
[ -f "${FILE_BASE_INI}/namelist.init_atmosphere" ] || { echo "ERRO: template não encontrado: ${FILE_BASE_INI}/namelist.init_atmosphere"; exit 1; }
[ -x "${DIR_EXE}/mpas_init_atmosphere" ] || { echo "ERRO: executável não encontrado: ${DIR_EXE}/mpas_init_atmosphere"; exit 1; }

N_MET=$(ls "${DIR_MET}/${PREFIXO}":* 2>/dev/null | wc -l)
[ "$N_MET" -gt 0 ] || { echo "ERRO: nenhum arquivo ${PREFIXO}:* encontrado em $DIR_MET"; exit 1; }

echo "--- init_atmosphere_model (LBC, config_init_case=9) [${REGION_NAME}] ---"
echo "  init.nc (malha vertical) : ${INIT_FILE}"
echo "  Meteorologia             : ${DIR_MET} (${N_MET} arquivos ${PREFIXO}:*)"
echo "  Período LBC              : ${LBC_START_TIME} -> ${LBC_STOP_TIME} (a cada ${LBC_INTERVAL_HHMMSS})"
echo "  NP                       : ${NP_RUN}"
echo "  Saída                    : ${WORK_DIR}/lbc.*.nc"

if ls "${WORK_DIR}"/lbc.*.nc &>/dev/null; then
    echo "Já existem arquivos lbc.*.nc em ${WORK_DIR} — nada a fazer."
    ls -lh "${WORK_DIR}"/lbc.*.nc
    exit 0
fi

mkdir -p "$WORK_DIR" && cd "$WORK_DIR"

# --- Malha, decomposição e dado inicial (fornece a malha vertical) ---
ln -sf "$INIT_FILE" "${REGION_NAME}.init.nc"
ln -sf "$GRAPH_PART" .
ln -sf "${DIR_EXE}/mpas_init_atmosphere" init_atmosphere_model

# --- Dados meteorológicos (selfgrib), mesmos do init ---
mkdir -p met_data
for f in "${DIR_MET}/${PREFIXO}":*; do
    ln -sf "$f" "met_data/$(basename "$f")"
done
ln -sf met_data/"${PREFIXO}":* .

# --- namelist.init_atmosphere (config_init_case=9, ver cabecalho) ---
cp -f "${FILE_BASE_INI}/namelist.init_atmosphere" .
sed -i "s/^\([[:space:]]*config_init_case[[:space:]]*=\).*/\1 9,/"                                   namelist.init_atmosphere
sed -i "s/^\([[:space:]]*config_start_time[[:space:]]*=\).*/\1 '${LBC_START_TIME}',/"                namelist.init_atmosphere
sed -i "s/^\([[:space:]]*config_stop_time[[:space:]]*=\).*/\1  '${LBC_STOP_TIME}',/"                 namelist.init_atmosphere
sed -i "s/^\([[:space:]]*config_met_prefix[[:space:]]*=\).*/\1   '${PREFIXO}',/"                     namelist.init_atmosphere
sed -i "s/^\([[:space:]]*config_nfglevels[[:space:]]*=\).*/\1     ${N_FGLEVELS},/"                    namelist.init_atmosphere
sed -i "s/^\([[:space:]]*config_block_decomp_file_prefix[[:space:]]*=\).*/\1 '${REGION_NAME}.graph.info.part.',/" namelist.init_atmosphere
# LBC nao mistura terreno (diferente do init.nc, config_init_case=7) --
# ver docs/regional_mpas_edi.pdf slide 19.
sed -i "s/^\([[:space:]]*config_blend_bdy_terrain[[:space:]]*=\).*/\1 false,/"                       namelist.init_atmosphere
# nao adiciona config_fg_interval automaticamente se ausente do template --
# garante que a chave existe dentro de &data_sources.
if ! grep -q "config_fg_interval" namelist.init_atmosphere; then
    sed -i "/&data_sources/a\\    config_fg_interval = ${FG_INTERVAL_SEC}" namelist.init_atmosphere
else
    sed -i "s/^\([[:space:]]*config_fg_interval[[:space:]]*=\).*/\1 ${FG_INTERVAL_SEC},/"            namelist.init_atmosphere
fi

# --- streams.init_atmosphere -- estrutura diferente do init.nc (case=7):
#     "input" aponta para o init.nc (malha vertical), e o stream de saida
#     e "lbc" (nao "output"). Escrito direto, nao adaptado do template de
#     producao (esse e generico so para o caso 7/static.nc -> init.nc).
#     Ver docs/regional_mpas_edi.pdf slides 19-20.
cat > streams.init_atmosphere << EOF
<streams>

<immutable_stream name="input"
                  type="input"
                  filename_template="${REGION_NAME}.init.nc"
                  input_interval="initial_only" />

<immutable_stream name="lbc"
                  type="output"
                  filename_template="lbc.\$Y-\$M-\$D_\$h.nc"
                  filename_interval="output_interval"
                  io_type="pnetcdf,cdf5"
                  packages="lbcs"
                  output_interval="${LBC_INTERVAL_HHMMSS}" />

</streams>
EOF

echo "--- Rodando init_atmosphere_model (LBC) com ${NP_RUN} processos ---"
ulimit -s unlimited
mpiexec -n "${NP_RUN}" -iface hsn0 -bind-to core -launcher fork ./init_atmosphere_model

if ls "${WORK_DIR}"/lbc.*.nc &>/dev/null; then
    echo "--- SUCESSO ---"
    ls -lh "${WORK_DIR}"/lbc.*.nc
else
    echo "--- ERRO: nenhum lbc.*.nc foi gerado ---"
    tail -20 log.init_atmosphere.0000.out 2>/dev/null
    exit 1
fi
