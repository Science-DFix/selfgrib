#!/bin/bash
# ==============================================================================
# run_mpas_atmosphere_15km.bash — Ungrib + Init MPAS-A (malha global 15km)
# Cluster: Jaci (CPTEC/INPE)
# Chamado por: master_run_15km.bash
#
# Adaptado de scripts/run_mpas_atmosphere.bash (malha 60km, x1.163842) para a
# malha global 15km (x1.2621442) baixada em rodada_global_15km/. Toda entrada
# e saida especifica deste experimento fica dentro de rodada_global_15km;
# recursos compartilhados do cluster (executaveis WPS, ambiente, dados GFS
# brutos) continuam apontando para os caminhos globais do usuario.
# ==============================================================================

MESH="${MESH:-x1.2621442}"

# --- Caminhos fixos (ajuste DIR_ROOT/DIR_BASE para o seu ambiente) ---
DIR_ROOT="${DIR_ROOT:-/lustre/projetos/satdas/diego_workdir}"
DIR_BASE="${DIR_BASE:-${DIR_ROOT}/SOURCE/rodada_global_15km}"
DIR_DATAOUT="${DIR_DATAOUT:-${DIR_BASE}/init}"
DIR_GRID="${DIR_GRID:-${DIR_BASE}/grid}"
DIR_STATIC="${DIR_STATIC:-${DIR_BASE}/static}"
FILE_BASE_15KM="${FILE_BASE_15KM:-${DIR_BASE}/FILE_BASE_15km}"

DIR_DATAIN_GFS="${DIR_DATAIN_GFS:-${DIR_ROOT}/SOURCE/datainput/gfs}"
DIR_GFS_OFICIAL="${DIR_GFS_OFICIAL:-/p/projetos/ioper/data/external/gfs_0p25}"
DIR_WPS="${DIR_WPS:-${DIR_ROOT}/WPS}"
ENV_ALL="${ENV_ALL:-${DIR_ROOT}/env_wrf_wps.bash}"

# DIR_EXE e PRECISION vem do master_run_15km.bash
DIR_EXE=${DIR_EXE:-"${DIR_ROOT}/build-mpich/bin"}
PRECISION=${PRECISION:-"double"}

# --- Ambiente ---
source "$ENV_ALL"

# --- Validacao ---
if [ -z "$TIMESTAMP" ]; then
    echo "ERRO: TIMESTAMP nao definido."
    exit 1
fi

ano=${TIMESTAMP:0:4}
mes=${TIMESTAMP:4:2}
dia=${TIMESTAMP:6:2}
hora=${TIMESTAMP:8:2}
start_date="${ano}-${mes}-${dia}_${hora}:00:00"
start_date_for_date="${ano}-${mes}-${dia} ${hora}:00:00"
# Previsao de 24h: so precisamos de meteorologia de fronteira ateh start+24h
end_date=$(date -d "${start_date_for_date} 1 day" "+%Y-%m-%d_%H:%M:%S")

WORK_DIR="${DIR_DATAOUT}/${TIMESTAMP}"
NP_RUN=${NP:-256}

echo "--- Init 15km [${PRECISION}]: $TIMESTAMP | start: ${start_date} | end: ${end_date} ---"

mkdir -p "$WORK_DIR" && cd "$WORK_DIR" || exit 1

# ==============================================================================
# CHECKUP: Verifica se o init.nc ja existe e esta completo
# ==============================================================================
INIT_FILE="${WORK_DIR}/${MESH}.init.nc"

if [ -f "${INIT_FILE}" ] && [ -s "${INIT_FILE}" ]; then
    if ncdump -h "${INIT_FILE}" &>/dev/null; then
        echo "============================================================"
        echo "  INIT JA EXISTE E ESTA VALIDO: ${INIT_FILE}"
        echo "  PULANDO ETAPA DE INITIALIZATION..."
        echo "============================================================"
        ls -lh "${INIT_FILE}"
        exit 0
    else
        echo "AVISO: Arquivo init.nc encontrado mas parece corrompido."
        echo "Removendo e recriando..."
        rm -f "${INIT_FILE}"
    fi
fi

# ==============================================================================
# FUNCAO: Encontra o melhor diretorio GFS disponivel (oficial -> backup)
# ==============================================================================
find_gfs_source() {
    local ts="$1"
    local a="${ts:0:4}" m="${ts:4:2}" d="${ts:6:2}" h="${ts:8:2}"

    local dir_oficial="${DIR_GFS_OFICIAL}/${a}/${m}/${d}/${h}"
    local prefix_oficial="gfs.t${h}z.pgrb2.0p25"

    if [ -d "$dir_oficial" ]; then
        local n_oficial=$(ls ${dir_oficial}/${prefix_oficial}.f*.grib2 2>/dev/null | wc -l)
        if [ "$n_oficial" -gt 0 ]; then
            echo "OFICIAL:${dir_oficial}:${prefix_oficial}"
            return 0
        fi
    fi

    local dir_backup="${DIR_DATAIN_GFS}/${ts}"
    local prefix_backup="gfs.0p25.${ts}"

    if [ -d "$dir_backup" ]; then
        local n_backup=$(ls ${dir_backup}/${prefix_backup}.f*.grib2 2>/dev/null | wc -l)
        if [ "$n_backup" -gt 0 ]; then
            echo "BACKUP:${dir_backup}:${prefix_backup}"
            return 0
        fi
    fi

    echo "NONE"
    return 1
}

echo "--- Verificando disponibilidade de GFS para ${TIMESTAMP} ---"

GFS_RESULT=$(find_gfs_source "$TIMESTAMP")
GFS_STATUS=$?

if [ $GFS_STATUS -ne 0 ] || [ "$GFS_RESULT" == "NONE" ]; then
    echo "================================================================"
    echo " ERRO: Nenhuma fonte de GFS disponivel para ${TIMESTAMP}"
    echo " Oficial: ${DIR_GFS_OFICIAL}/${ano}/${mes}/${dia}/${hora}"
    echo " Backup:  ${DIR_DATAIN_GFS}/${TIMESTAMP}"
    echo "================================================================"
    exit 1
fi

GFS_SOURCE=$(echo "$GFS_RESULT" | cut -d: -f1)
GFS_DIR=$(echo "$GFS_RESULT" | cut -d: -f2)
GFS_PREFIX=$(echo "$GFS_RESULT" | cut -d: -f3)

# ==============================================================================
# Lista EXPLICITA de forecast hours necessarios (start_date .. end_date, a cada
# INTERVAL_HOURS) em vez do glob "f*.grib2" cego. O repositorio oficial (IOPER)
# guarda o GFS completo (ate ~384h), entao "f*.grib2" pegava ~276 arquivos e o
# ungrib.exe processava tudo isso so pra usar as 9 horas realmente precisas.
# ==============================================================================
RUN_HOURS=$(( ($(date -d "${end_date//_/ }" +%s) - $(date -d "${start_date_for_date}" +%s)) / 3600 ))
INTERVAL_HOURS=3   # tem que bater com interval_seconds=10800 do namelist.wps

GFS_FILES=()
for (( fh=0; fh<=RUN_HOURS; fh+=INTERVAL_HOURS )); do
    fh3=$(printf "%03d" "$fh")
    # Glob por forecast hour individual: cobre tanto o formato do backup local
    # ("${prefix}.f000.grib2") quanto o do repositorio oficial IOPER, que tem
    # o timestamp DEPOIS do forecast hour ("${prefix}.f000.2026013100.grib2")
    matches=(${GFS_DIR}/${GFS_PREFIX}.f${fh3}.*grib2)
    if [ ! -e "${matches[0]}" ]; then
        echo "ERRO: arquivo GFS esperado nao encontrado para f${fh3}: ${GFS_DIR}/${GFS_PREFIX}.f${fh3}.*grib2"
        exit 1
    fi
    if [ "${#matches[@]}" -gt 1 ]; then
        echo "ERRO: mais de um arquivo GFS casou com f${fh3}, ambiguo: ${matches[*]}"
        exit 1
    fi
    GFS_FILES+=("${matches[0]}")
done

echo "  Fonte: ${GFS_SOURCE} | Dir: ${GFS_DIR} | Arquivos necessarios: ${#GFS_FILES[@]} (f000..f${RUN_HOURS} a cada ${INTERVAL_HOURS}h)"

# --- Links (malha 15km extraida em DIR_GRID/DIR_STATIC dentro do experimento) ---
ln -sf "${DIR_WPS}/ungrib.exe" .
ln -sf "${DIR_WPS}/link_grib.csh" .
ln -sf "${DIR_WPS}/ungrib/Variable_Tables/Vtable.GFS" Vtable
ln -sf "${DIR_GRID}/${MESH}.grid.nc" .
ln -sf "${DIR_STATIC}/${MESH}.static.nc" .
ln -sf "${DIR_GRID}/${MESH}.graph.info.part.${NP_RUN}" .
ln -sf "${DIR_EXE}/mpas_init_atmosphere" init_atmosphere_model

# --- namelist.wps ---
cp "${FILE_BASE_15KM}/namelist.wps" .
sed -i "s/^[[:space:]]*start_date[[:space:]]*=.*/ start_date = '${start_date}',/" namelist.wps
sed -i "s/^[[:space:]]*end_date[[:space:]]*=.*/ end_date   = '${end_date}',/"   namelist.wps

echo "--- Executando ungrib.exe (fonte: ${GFS_SOURCE}) ---"
./link_grib.csh "${GFS_FILES[@]}"

if [ ! -f "namelist.wps" ]; then
    echo "ERRO: namelist.wps nao encontrado"
    exit 1
fi
./ungrib.exe > log.ungrib.out 2>&1

NFILE=$(ls FILE:* 2>/dev/null | wc -l)
if [ "$NFILE" -eq 0 ]; then
    echo "ERRO: ungrib nao gerou arquivos FILE:*"
    tail -10 log.ungrib.out
    exit 1
fi
echo "ungrib OK — ${NFILE} arquivos FILE:* gerados (fonte: ${GFS_SOURCE})"

mkdir -p met_data
mv FILE:* met_data/
ln -sf met_data/FILE:* .

# --- namelist.init_atmosphere ---
cp "${FILE_BASE_15KM}/namelist.init_atmosphere" .
sed -i "s/^[[:space:]]*config_start_time[[:space:]]*=.*/ config_start_time = '${start_date}',/" namelist.init_atmosphere
sed -i "s/^[[:space:]]*config_stop_time[[:space:]]*=.*/ config_stop_time  = '${start_date}',/" namelist.init_atmosphere

# --- streams.init_atmosphere ---
cp "${FILE_BASE_15KM}/streams.init_atmosphere" .

# --- Execucao ---
ulimit -s unlimited
echo "Rodando init_atmosphere_model [${PRECISION}] com ${NP_RUN} processos..."
mpiexec -n ${NP_RUN} -iface hsn0 -bind-to core -launcher fork ./init_atmosphere_model

if [ $? -eq 0 ]; then
    echo "--- Init SUCESSO: $TIMESTAMP [${PRECISION}] (GFS: ${GFS_SOURCE}) ---"

    if [ -f "${INIT_FILE}" ] && [ -s "${INIT_FILE}" ]; then
        echo "init.nc gerado com sucesso:"
        ls -lh "${INIT_FILE}"
    else
        echo "ERRO: init.nc nao foi gerado ou esta vazio!"
        exit 1
    fi

    exit 0
else
    echo "--- Init ERRO: $TIMESTAMP [${PRECISION}] ---"
    tail -20 log.init_atmosphere.0000.out 2>/dev/null
    exit 1
fi
