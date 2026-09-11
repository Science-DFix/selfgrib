#!/bin/bash
#PBS -S /bin/bash
#PBS -q pesqmidi
#PBS -l select=1:ncpus=256
#PBS -l walltime=02:00:00
#PBS -N MPAS-Invariant-15km
#PBS -j oe
#PBS -o MPAS-Invariant-15km.out

# ==============================================================================
# Gera x1.2621442.invariant.nc (malha global 15km) com precisao SIMPLES
# Executavel: build-mpich-single (mesmo build usado pelo init/forecast deste
# experimento com PRECISION=single em master_run_15km.bash). O caminho
# TESTE_MPAS_JEDI/build_mpas_sp usado no job_invariant.sh original (60km) nao
# existe mais no Jaci -- corrigido apos falha real (job terminou em 8s sem
# nenhum log do MPAS, executavel/ambiente nao encontrados).
# ==============================================================================

# Ajuste DIR_ROOT/DIR_BASE para o seu ambiente (ex: via `qsub -v DIR_ROOT=...`)
DIR_ROOT="${DIR_ROOT:-/lustre/projetos/satdas/diego_workdir}"
DIR_BUILD="${DIR_BUILD:-${DIR_ROOT}/build-mpich-single}"
DIR_PHYSICS="${DIR_PHYSICS:-${DIR_BUILD}/_deps/mpas_data-src/atmosphere/physics_wrf/files}"
DIR_BASE="${DIR_BASE:-${DIR_ROOT}/SOURCE/rodada_global_15km}"
DIR_WORK="${DIR_WORK:-${DIR_BASE}/invariant}"
DIR_GRID="${DIR_GRID:-${DIR_BASE}/grid}"
DIR_STATIC="${DIR_STATIC:-${DIR_BASE}/static}"
ENV_ALL="${ENV_ALL:-${DIR_ROOT}/env_wrf_wps.bash}"

# Mesmo ambiente usado pelos demais passos deste experimento (init/forecast)
source "$ENV_ALL"

mkdir -p "${DIR_WORK}" && cd "${DIR_WORK}" || exit 1

# Linka executavel de precisao simples
ln -sf "${DIR_BUILD}/bin/mpas_init_atmosphere" ./mpas_init_atmosphere

# Linka tabelas de fisica do build correto
for f in "${DIR_PHYSICS}"/*.TBL "${DIR_PHYSICS}"/*.DBL \
          "${DIR_PHYSICS}"/*DATA "${DIR_PHYSICS}"/VERSION \
          "${DIR_PHYSICS}"/COMPATIBILITY; do
    [ -e "$f" ] && ln -sf "$f" ./
done

# Entrada: static.nc + graph.info.part.<NP> da malha 15km (extraidos dos tar.gz)
# NP=256 = mesma particao usada no init/forecast (unico valor <=256 cores
# de 1 no do Jaci disponivel no tarball; 128 nao existe para esta malha)
ln -sf "${DIR_STATIC}/x1.2621442.static.nc" .
ln -sf "${DIR_GRID}/x1.2621442.graph.info.part.256" .

# Namelist/streams especificos da malha 15km
cp "${DIR_BASE}/FILE_BASE_15km/invariant/namelist.init_atmosphere" .
cp "${DIR_BASE}/FILE_BASE_15km/invariant/streams.init_atmosphere" .

ulimit -s unlimited

echo "Iniciando geracao do Invariant 15km (precisao simples) em: $(date)"
echo "Diretorio: $(pwd)"
echo "Executavel: $(readlink -f mpas_init_atmosphere)"
if [ ! -x "$(readlink -f mpas_init_atmosphere)" ]; then
    echo "ERRO: executavel mpas_init_atmosphere nao existe/nao e executavel em ${DIR_BUILD}/bin"
    exit 1
fi
echo "Verificando namelist:"
grep -E "config_static_interp|config_native_gwd_static|config_vertical_grid|config_met_interp" namelist.init_atmosphere

mpiexec -n 256 -iface hsn0 -bind-to core -launcher fork ./mpas_init_atmosphere

echo "Finalizado em: $(date)"

if [ -f "x1.2621442.invariant.nc" ]; then
    echo "SUCESSO — tamanho: $(du -sh x1.2621442.invariant.nc | cut -f1)"
    ncdump -h x1.2621442.invariant.nc | grep "^\s\+float\|^\s\+double" | head -5
else
    echo "ERRO — x1.2621442.invariant.nc nao foi gerado"
    tail -20 log.init_atmosphere.0000.out 2>/dev/null
    exit 1
fi
