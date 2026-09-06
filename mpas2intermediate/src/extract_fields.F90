! extract_fields
!
! Le um arquivo MPAS-A nativo (history.nc ou um *.region.nc gerado pelo
! MPAS-Limited-Area a partir de um history.nc -- ambos tem os mesmos campos)
! e produz um netCDF "extracted_fields.nc", AINDA NA MALHA NATIVA (dimensao
! nCells preservada, mesma ordem de celulas do arquivo de entrada), com:
!
!   - TT, UU, VV, GHT, SPECHUMD  em pressure_levels::plevels_hPa (55 niveis)
!   - TT, UU, VV, SPECHUMD       no pseudo-nivel de superficie (t2m/u10/v10/q2)
!   - PSFC, SKINTEMP, SOILHGT, LANDSEA, SST, SNOW, SEAICE  (2D, superficie)
!   - PMSL                        (pseudo-nivel nivel-do-mar, via compute_slp)
!   - SM000010/SM010040/SM040100/SM100200 e ST-equivalentes (solo, 4 camadas
!     Noah, copia direta de smois/tslb -- ja na convencao correta, sem
!     necessidade de interpolacao)
!
! Este arquivo de saida e o argumento "field file" do convert_mpas (segundo
! argumento; o primeiro deve ser um arquivo com a malha/conectividade, ex.
! o proprio SouthAmerica.region.nc ou um *.static.nc): o convert_mpas faz o
! remapeamento horizontal (malha nativa -> lat-lon) de cada campo aqui
! presente. O resultado (latlon.nc) e o insumo do programa pack_intermediate,
! que escreve o formato binario final que o init_atmosphere_model le.
!
! Uso: extract_fields <entrada.nc> <saida.nc>

program extract_fields

   use mpas_kind_types,  only : RKIND
   use pressure_levels,  only : N_PLEVELS, N_ALWAYS_EXTRAP, plevels_hPa, LEVEL_SFC_PA, LEVEL_SEALVL_PA
   use interp_vertical,  only : interp_tofixed_pressure, compute_slp
   use netcdf

   implicit none

   character(len=1024) :: infile, outfile

   integer :: ncid, dimid, ncid_out
   integer :: nCells, nVertLevels, nSoilLevels

   ! campos 3D nativos (nVertLevels, nCells)
   real(kind=RKIND), allocatable :: pressure(:,:), theta(:,:), qv(:,:), relhum(:,:)
   real(kind=RKIND), allocatable :: uzonal(:,:), umerid(:,:)
   real(kind=RKIND), allocatable :: zgrid(:,:)          ! (nVertLevels+1, nCells)
   real(kind=RKIND), allocatable :: temperature(:,:), height_mass(:,:), spechum(:,:)

   ! campos 2D nativos (nCells)
   real(kind=RKIND), allocatable :: psfc(:), skintemp(:), xland(:), sst(:)
   real(kind=RKIND), allocatable :: snow(:), snowh(:), xice(:)
   real(kind=RKIND), allocatable :: t2m(:), u10(:), v10(:), q2(:)
   real(kind=RKIND), allocatable :: soilhgt(:), landsea(:), seaice(:), pmsl(:)

   ! solo (nSoilLevels, nCells)
   real(kind=RKIND), allocatable :: smois(:,:), tslb(:,:)

   ! malha (para escrever no arquivo de saida, mesma ordem/indice de celula)
   real(kind=RKIND), allocatable :: latCell(:), lonCell(:)
   integer, allocatable :: indexToCellID(:)

   ! buffers para interpolacao vertical
   real(kind=RKIND), allocatable :: press_in(:,:), field_in(:,:), press_out(:,:)
   real(kind=RKIND), allocatable :: tt_plev(:,:), uu_plev(:,:), vv_plev(:,:)
   real(kind=RKIND), allocatable :: ght_plev(:,:), spechumd_plev(:,:), rh_plev(:,:)

   real(kind=RKIND), allocatable :: rh2m(:)

   integer :: k, kk
   real(kind=RKIND), parameter :: P0 = 100000.0_RKIND
   real(kind=RKIND), parameter :: RCP = 0.285714_RKIND

   if (command_argument_count() < 2) then
      write(0,*) 'Uso: extract_fields <entrada.nc> <saida.nc>'
      write(0,*) '  <entrada.nc> precisa ter as variaveis pressure, zgrid, theta, qv,'
      write(0,*) '  relhum, uReconstructZonal/Meridional prontas (ex.: history.nc).'
      write(0,*) '  Arquivos que nao tem essas variaveis prontas (ex.: mpasout.nc,'
      write(0,*) '  que so tem pressure_p/pressure_base e nao tem zgrid) nao sao'
      write(0,*) '  fonte valida para esta ferramenta.'
      stop 1
   end if
   call get_command_argument(1, infile)
   call get_command_argument(2, outfile)

   call check( nf90_open(trim(infile), NF90_NOWRITE, ncid) )

   call check( nf90_inq_dimid(ncid, 'nCells', dimid) )
   call check( nf90_inquire_dimension(ncid, dimid, len=nCells) )
   call check( nf90_inq_dimid(ncid, 'nVertLevels', dimid) )
   call check( nf90_inquire_dimension(ncid, dimid, len=nVertLevels) )
   call check( nf90_inq_dimid(ncid, 'nSoilLevels', dimid) )
   call check( nf90_inquire_dimension(ncid, dimid, len=nSoilLevels) )

   write(0,*) 'nCells = ', nCells, '  nVertLevels = ', nVertLevels, '  nSoilLevels = ', nSoilLevels
   if (nSoilLevels /= 4) then
      write(0,*) 'AVISO: nSoilLevels != 4 -- a convencao Noah 10/40/100/200cm assume 4 camadas.'
   end if

   allocate(pressure(nVertLevels,nCells), theta(nVertLevels,nCells), qv(nVertLevels,nCells))
   allocate(relhum(nVertLevels,nCells))
   allocate(uzonal(nVertLevels,nCells), umerid(nVertLevels,nCells))
   allocate(zgrid(nVertLevels+1,nCells))
   allocate(temperature(nVertLevels,nCells), height_mass(nVertLevels,nCells), spechum(nVertLevels,nCells))

   allocate(psfc(nCells), skintemp(nCells), xland(nCells), sst(nCells))
   allocate(snow(nCells), snowh(nCells), xice(nCells))
   allocate(t2m(nCells), u10(nCells), v10(nCells), q2(nCells))
   allocate(soilhgt(nCells), landsea(nCells), seaice(nCells), pmsl(nCells))
   allocate(smois(nSoilLevels,nCells), tslb(nSoilLevels,nCells))
   allocate(latCell(nCells), lonCell(nCells), indexToCellID(nCells))
   allocate(rh2m(nCells))

   call read3d(ncid, 'pressure', pressure, nVertLevels, nCells)
   call read3d(ncid, 'theta', theta, nVertLevels, nCells)
   call read3d(ncid, 'qv', qv, nVertLevels, nCells)
   call read3d(ncid, 'relhum', relhum, nVertLevels, nCells)
   call read3d(ncid, 'uReconstructZonal', uzonal, nVertLevels, nCells)
   call read3d(ncid, 'uReconstructMeridional', umerid, nVertLevels, nCells)
   call read2d_static(ncid, 'zgrid', zgrid, nVertLevels+1, nCells)

   call read2d(ncid, 'surface_pressure', psfc, nCells)
   call read2d(ncid, 'skintemp', skintemp, nCells)
   call read2d(ncid, 'xland', xland, nCells)
   call read2d(ncid, 'sst', sst, nCells)
   call read2d(ncid, 'snow', snow, nCells)
   call read2d(ncid, 'snowh', snowh, nCells)
   call read2d(ncid, 'xice', xice, nCells)
   call read2d(ncid, 't2m', t2m, nCells)
   call read2d(ncid, 'u10', u10, nCells)
   call read2d(ncid, 'v10', v10, nCells)
   call read2d(ncid, 'q2', q2, nCells)

   call read3d(ncid, 'smois', smois, nSoilLevels, nCells)
   call read3d(ncid, 'tslb', tslb, nSoilLevels, nCells)

   call read1d_static(ncid, 'latCell', latCell, nCells)
   call read1d_static(ncid, 'lonCell', lonCell, nCells)
   call read1d_static_int(ncid, 'indexToCellID', indexToCellID, nCells)

   call check( nf90_close(ncid) )

   !-------------------------------------------------------------------
   ! Campos derivados na malha nativa
   !-------------------------------------------------------------------
   do k = 1, nVertLevels
      temperature(k,:) = theta(k,:) * (pressure(k,:)/P0)**RCP
      height_mass(k,:) = 0.5_RKIND*(zgrid(k,:) + zgrid(k+1,:))
      spechum(k,:)     = qv(k,:) / (1.0_RKIND + qv(k,:))
   end do

   soilhgt(:) = zgrid(1,:)                 ! altura da superficie = terreno
   landsea(:) = 2.0_RKIND - xland(:)       ! xland: 1=land,2=water -> landsea: 1=land,0=water

   !-------------------------------------------------------------------
   ! RH a 2m: nao existe campo nativo pronto (so q2 = umidade especifica).
   ! Calculado via pressao de vapor (a partir de q2+psfc) sobre pressao de
   ! saturacao de Bolton (1980) -- mesma referencia ja usada em
   ! mpas_isobaric_diagnostics.F para dewpoint, aqui invertida para RH.
   !-------------------------------------------------------------------
   block
      real(kind=RKIND) :: e_vap, e_sat
      integer :: iCell
      do iCell = 1, nCells
         e_vap = q2(iCell) * psfc(iCell) / (0.622_RKIND + 0.378_RKIND * q2(iCell))
         e_sat = 611.2_RKIND * exp(17.67_RKIND * (t2m(iCell)-273.15_RKIND) / (t2m(iCell)-29.65_RKIND))
         rh2m(iCell) = 100.0_RKIND * e_vap / e_sat
         rh2m(iCell) = max(0.0_RKIND, min(100.0_RKIND, rh2m(iCell)))
      end do
   end block
   seaice(:)  = xice(:)                    ! fracao (0-1); flag inteiro fica a criterio do leitor

   !-------------------------------------------------------------------
   ! PMSL via compute_slp (mesma rotina que o MPAS usa em diag.nc/mslp)
   !-------------------------------------------------------------------
   block
      real(kind=RKIND) :: p_hpa(nVertLevels,nCells)
      real(kind=RKIND) :: scalars1(1,nVertLevels,nCells)
      p_hpa = pressure / 100.0_RKIND
      scalars1(1,:,:) = qv
      call compute_slp(nCells, nVertLevels, 1, temperature, zgrid, p_hpa, 1, scalars1, pmsl)
      pmsl = pmsl * 100.0_RKIND   ! compute_slp retorna hPa -- converter para Pa
   end block

   !-------------------------------------------------------------------
   ! Interpolacao vertical (niveis nativos -> 55 niveis de pressao fixa)
   ! IMPORTANTE: inversao de indice exigida por interp_tofixed_pressure
   ! (indice 1 = topo / menor pressao) -- ver nota em pressure_levels.F90
   !-------------------------------------------------------------------
   allocate(press_in(nCells,nVertLevels), field_in(nCells,nVertLevels))
   allocate(press_out(nCells,N_PLEVELS))
   allocate(tt_plev(nCells,N_PLEVELS), uu_plev(nCells,N_PLEVELS), vv_plev(nCells,N_PLEVELS))
   allocate(ght_plev(nCells,N_PLEVELS), spechumd_plev(nCells,N_PLEVELS), rh_plev(nCells,N_PLEVELS))

   do k = 1, nVertLevels
      kk = nVertLevels + 1 - k
      press_in(:,kk) = pressure(k,:) / 100.0_RKIND
   end do
   do k = 1, N_PLEVELS
      press_out(:,k) = plevels_hPa(k)
   end do

   call interp_from_native(temperature, tt_plev,       'TT')
   call interp_from_native(uzonal,      uu_plev,       'UU')
   call interp_from_native(umerid,      vv_plev,       'VV')
   call interp_from_native(height_mass, ght_plev,       'GHT')
   call interp_from_native(spechum,     spechumd_plev, 'SPECHUMD')
   call interp_from_native(relhum,      rh_plev,       'RH')

   !-------------------------------------------------------------------
   ! Correcao fisica de GHT nos N_ALWAYS_EXTRAP primeiros niveis de
   ! plevels_hPa -- MESMO CONJUNTO DE INDICES PARA TODAS AS CELULAS (ver
   ! "BUG 4" em pressure_levels.F90 para o porque a versao anterior,
   ! condicional por celula, nao bastava).
   !
   ! interp_tofixed_pressure extrapola TODOS os campos acima do topo
   ! nativo com a mesma formula (field_out = field_in(topo) *
   ! pressao_alvo/pressao_topo), valida para campos que tendem a zero com
   ! a pressao mas FISICAMENTE INVERTIDA para altura: como
   ! pressao_alvo < pressao_topo nesses niveis, ela reduz a altura em vez
   ! de aumentar.
   !
   ! Uma correcao condicional por celula (so recalcular quando
   ! plevels_hPa(k) < topo_real_desta_celula) parecia certa isoladamente,
   ! mas quebrava a interpolacao HORIZONTAL do proximo estagio
   ! (convert_mpas, malha nativa -> grade lat-lon): celulas vizinhas cujo
   ! topo real cai em lados opostos de um mesmo plevels_hPa(k) tratam
   ! esse nivel de formas diferentes (uma extrapola, a outra usa dado
   ! real) -- uma troca de regime espacial que, ao ser misturada pelo
   ! remapeamento horizontal, pode gerar um perfil nao-monotonico no
   ! ponto de grade resultante (confirmado ao vivo: o
   ! init_atmosphere_model voltou a travar em
   ! "extrap_type == 2 not implemented for target_z >= zf(1,nz)", mesmo
   ! com zero inversoes verificadas na malha nativa global).
   !
   ! Por isso a correcao usa um conjunto FIXO de indices (N_ALWAYS_EXTRAP),
   ! os MESMOS para toda celula, sempre recalculados com extrapolacao
   ! hipsometrica isotermica ancorada no topo nativo REAL de cada celula
   ! (que varia suavemente no espaco, ao contrario de uma decisao
   ! condicional por nivel):
   !
   !   z(k) = z_topo_real + (Rd*T_topo_real/g) * ln(p_topo_real/p(k))
   !
   ! N_ALWAYS_EXTRAP foi escolhido com margem sobre o pior caso observado
   ! numa malha global real (topo nativo nunca excede 13.86 hPa) -- ver
   ! comentario em pressure_levels.F90. Como p(k) < p_topo_real para todo
   ! k <= N_ALWAYS_EXTRAP (garantido pela margem), ln(...) > 0 e a altura
   ! resultante e SEMPRE maior que z_topo_real, crescendo
   ! monotonicamente conforme a pressao cai. Nao precisa ser fisicamente
   ! exata (isotermica e uma simplificacao grosseira da estratosfera
   ! real): nenhuma celula real do dominio MPAS chega perto dessas
   ! altitudes, o unico requisito e monotonicidade + consistencia
   ! espacial entre celulas vizinhas.
   !-------------------------------------------------------------------
   block
      real(kind=RKIND), parameter :: RD_GAS = 287.05_RKIND, GRAV = 9.80665_RKIND
      real(kind=RKIND) :: p_topo_real, z_topo_real, t_topo_real
      integer :: iCell, k2
      do iCell = 1, nCells
         p_topo_real = pressure(nVertLevels,iCell) / 100.0_RKIND   ! hPa, nivel nativo mais alto DESTA celula
         z_topo_real = height_mass(nVertLevels,iCell)
         t_topo_real = temperature(nVertLevels,iCell)
         do k2 = 1, N_ALWAYS_EXTRAP
            ght_plev(iCell,k2) = z_topo_real + (RD_GAS*t_topo_real/GRAV) * log(p_topo_real/plevels_hPa(k2))
         end do
      end do
   end block

   !-------------------------------------------------------------------
   ! BUG 5 (2026-09-05, mesmo dia, ainda): platos de GHT identicos
   ! travam o init_atmosphere_model. A extrapolacao "abaixo do solo"
   ! (persistencia constante, ver interp_vertical.F90) faz os ULTIMOS
   ! niveis de pressao (mais proximos da superficie) ficarem com a
   ! MESMA altura EXATA quando a pressao real de superficie da celula e
   ! menor que 2 ou mais dos nossos niveis fixos -- ja documentado antes
   ! como "plato esperado, sem inversao real". Confirmado ao vivo que
   ! isso E um bug real: o consumidor (mpas_init_atm_cases.F, rotina
   ! "Adjust surface pressure for difference in topography") extrapola
   ! log(PSFC) usando os DOIS PRIMEIROS pontos do perfil ordenado por
   ! altura com uma divisao (zf(2)-zf(1)) -- se esses dois pontos tem a
   ! MESMA altura (nosso plato), a divisao é por zero, dando
   ! Infinity/NaN em PSFC. Reproduzido numericamente com dados reais:
   ! confirmado NaN/Infinity exatamente nesse ponto. Resultado real:
   ! ~12% das celulas da malha regional (2089 de 17064) saiam com
   ! surface_pressure=NaN no init.nc, causando SIGSEGV na inicializacao
   ! da fisica do mpas_atmosphere.
   !
   ! PRIMEIRA CORRECAO (insuficiente): so garantir monotonicidade ESTRITA
   ! com uma perturbacao minima (0.01m) onde havia empate, sem mexer na
   ! fisica. Isso so trocou o bug: quebrar o empate com uma diferenca de
   ! altura MINUSCULA entre os dois primeiros pontos, mas com uma
   ! diferenca de PRESSAO normal entre eles, produz uma slope
   ! log(p)-vs-z ABSURDAMENTE INGREME (ex.: -0.6/metro). Extrapolando
   ! essa slope por uma distancia normal (dezenas a centenas de metros,
   ! ate a altura real do terreno), o resultado explode numericamente
   ! (confirmado ao vivo: log(psfc) chegou a 113, ou seja psfc~1e49) --
   ! pior que o NaN original. Resultado real: 31 celulas (regiao andina,
   ! terreno de baixa/media elevacao mas ainda assim fora do "plato")
   ! continuaram com surface_pressure=NaN/Inf.
   !
   ! CORRECAO DE VERDADE: como o GFS/ungrib real faz isso -- dados de
   ! producao (GFS) cobrem niveis de pressao ate 1000 hPa em todo o
   ! globo, inclusive sobre terreno elevado onde 1000 hPa fica
   ! "debaixo do chao"; o NCEP ja extrapola esses campos abaixo do
   ! terreno com o METODO HIPSOMETRICO (lapse-rate padrao), NUNCA
   ! persistencia constante -- por isso o perfil altura-vs-pressao do
   ! GFS e sempre suave/continuo, nunca tem dois niveis com a mesma
   ! altura, e a rotina "Adjust surface pressure" do MPAS nunca ve esse
   ! bug em producao. A formula "persistencia constante" que usamos
   ! (interp_vertical.F90) foi emprestada do mpas_isobaric_diagnostics.F,
   ! pensada para campos de SAIDA/diagnostico em poucos niveis padrao --
   ! nao para realimentar o init_atmosphere_model. Usar persistencia
   ! constante especificamente para GHT foi uso indevido dessa formula
   ! fora do contexto para o qual foi desenhada.
   !
   ! Por isso a correcao real e replicar o que o GFS faz: extrapolacao
   ! hipsometrica (mesma formula ja usada no topo, BUG 2/3/4 acima) para
   ! os niveis "abaixo do solo", ancorada na pressao/altura/temperatura
   ! REAIS do primeiro nivel nativo de cada celula (k=1, sempre dado
   ! real, nunca extrapolado). Diferente do topo (BUG 4), aqui a
   ! condicao "abaixo do solo" varia MUITO entre celulas (pressao de
   ! superficie vai de ~300 hPa nos Andes a ~1030 hPa ao nivel do mar) --
   ! um indice fixo tipo N_ALWAYS_EXTRAP descartaria dado real demais.
   ! A troca de regime espacial entre celulas vizinhas e um risco menor
   ! aqui do que no topo: esses pontos abaixo do solo nunca sao usados
   ! diretamente pelos niveis verticais reais do modelo (que ficam
   ! sempre acima do terreno) -- so servem para a extrapolacao de PSFC,
   ! que so precisa de uma slope fisicamente razoavel, nao de precisao
   ! entre celulas vizinhas.
   !-------------------------------------------------------------------
   block
      real(kind=RKIND), parameter :: RD_GAS = 287.05_RKIND, GRAV = 9.80665_RKIND
      real(kind=RKIND) :: p_chao_real, z_chao_real, t_chao_real
      integer :: iCell, k2
      do iCell = 1, nCells
         p_chao_real = pressure(1,iCell) / 100.0_RKIND   ! hPa, nivel nativo mais baixo (superficie) DESTA celula
         z_chao_real = height_mass(1,iCell)
         t_chao_real = temperature(1,iCell)
         do k2 = 1, N_PLEVELS
            if (plevels_hPa(k2) > p_chao_real) then
               ght_plev(iCell,k2) = z_chao_real - (RD_GAS*t_chao_real/GRAV) * log(plevels_hPa(k2)/p_chao_real)
            end if
         end do
      end do
   end block

   write(0,*) 'Interpolacao vertical concluida para TT, UU, VV, GHT, SPECHUMD, RH (', N_PLEVELS, ' niveis).'

   !-------------------------------------------------------------------
   ! Escreve o netCDF de saida (malha nativa, pronto para o convert_mpas)
   !-------------------------------------------------------------------
   call write_output()

   write(0,*) 'Arquivo escrito: ', trim(outfile)

contains

   subroutine interp_from_native(native_field, plev_field, label)
      real(kind=RKIND), intent(in)  :: native_field(nVertLevels,nCells)
      real(kind=RKIND), intent(out) :: plev_field(nCells,N_PLEVELS)
      character(len=*), intent(in)  :: label
      integer :: kloc, kkloc
      do kloc = 1, nVertLevels
         kkloc = nVertLevels + 1 - kloc
         field_in(:,kkloc) = native_field(kloc,:)
      end do
      call interp_tofixed_pressure(nCells, nVertLevels, N_PLEVELS, press_in, field_in, press_out, plev_field)
   end subroutine interp_from_native

   subroutine check(status)
      integer, intent(in) :: status
      if (status /= nf90_noerr) then
         write(0,*) 'Erro NetCDF: ', trim(nf90_strerror(status))
         stop 1
      end if
   end subroutine check

   subroutine read3d(ncid_in, varname, arr, nz, nc)
      integer, intent(in) :: ncid_in, nz, nc
      character(len=*), intent(in) :: varname
      real(kind=RKIND), intent(out) :: arr(nz,nc)
      integer :: vid
      call check( nf90_inq_varid(ncid_in, varname, vid) )
      call check( nf90_get_var(ncid_in, vid, arr, start=(/1,1,1/), count=(/nz,nc,1/)) )
   end subroutine read3d

   subroutine read2d(ncid_in, varname, arr, nc)
      integer, intent(in) :: ncid_in, nc
      character(len=*), intent(in) :: varname
      real(kind=RKIND), intent(out) :: arr(nc)
      integer :: vid
      call check( nf90_inq_varid(ncid_in, varname, vid) )
      call check( nf90_get_var(ncid_in, vid, arr, start=(/1,1/), count=(/nc,1/)) )
   end subroutine read2d

   ! variaveis SEM dimensao Time (malha/estatico), 2D no arquivo
   subroutine read2d_static(ncid_in, varname, arr, nz, nc)
      integer, intent(in) :: ncid_in, nz, nc
      character(len=*), intent(in) :: varname
      real(kind=RKIND), intent(out) :: arr(nz,nc)
      integer :: vid
      call check( nf90_inq_varid(ncid_in, varname, vid) )
      call check( nf90_get_var(ncid_in, vid, arr, start=(/1,1/), count=(/nz,nc/)) )
   end subroutine read2d_static

   subroutine read1d_static(ncid_in, varname, arr, nc)
      integer, intent(in) :: ncid_in, nc
      character(len=*), intent(in) :: varname
      real(kind=RKIND), intent(out) :: arr(nc)
      integer :: vid
      call check( nf90_inq_varid(ncid_in, varname, vid) )
      call check( nf90_get_var(ncid_in, vid, arr) )
   end subroutine read1d_static

   subroutine read1d_static_int(ncid_in, varname, arr, nc)
      integer, intent(in) :: ncid_in, nc
      character(len=*), intent(in) :: varname
      integer, intent(out) :: arr(nc)
      integer :: vid
      call check( nf90_inq_varid(ncid_in, varname, vid) )
      call check( nf90_get_var(ncid_in, vid, arr) )
   end subroutine read1d_static_int

   subroutine write_output()
      integer :: dimCells, dimPLev, dimSoil, dimTime
      integer :: vLat, vLon, vIdx
      integer :: vTT, vUU, vVV, vGHT, vSPECHUMD, vRH
      integer :: vTTsfc, vUUsfc, vVVsfc, vSPECHUMDsfc, vRHsfc
      integer :: vPSFC, vPMSL, vSKINTEMP, vSOILHGT, vLANDSEA, vSST, vSNOW, vSEAICE
      integer :: vSM(4), vST(4)
      character(len=16) :: soilnames_sm(4), soilnames_st(4)

      soilnames_sm = (/ 'SM000010', 'SM010040', 'SM040100', 'SM100200' /)
      soilnames_st = (/ 'ST000010', 'ST010040', 'ST040100', 'ST100200' /)

      call check( nf90_create(trim(outfile), NF90_CLOBBER, ncid_out) )

      call check( nf90_def_dim(ncid_out, 'nCells', nCells, dimCells) )
      call check( nf90_def_dim(ncid_out, 'nPressureLevels', N_PLEVELS, dimPLev) )
      call check( nf90_def_dim(ncid_out, 'nSoilLevels', nSoilLevels, dimSoil) )
      call check( nf90_def_dim(ncid_out, 'Time', NF90_UNLIMITED, dimTime) )

      call check( nf90_def_var(ncid_out, 'latCell', NF90_DOUBLE, (/dimCells/), vLat) )
      call check( nf90_def_var(ncid_out, 'lonCell', NF90_DOUBLE, (/dimCells/), vLon) )
      call check( nf90_def_var(ncid_out, 'indexToCellID', NF90_INT, (/dimCells/), vIdx) )

      call check( nf90_def_var(ncid_out, 'TT',       NF90_DOUBLE, (/dimCells,dimPLev,dimTime/), vTT) )
      call check( nf90_def_var(ncid_out, 'UU',       NF90_DOUBLE, (/dimCells,dimPLev,dimTime/), vUU) )
      call check( nf90_def_var(ncid_out, 'VV',       NF90_DOUBLE, (/dimCells,dimPLev,dimTime/), vVV) )
      call check( nf90_def_var(ncid_out, 'GHT',      NF90_DOUBLE, (/dimCells,dimPLev,dimTime/), vGHT) )
      call check( nf90_def_var(ncid_out, 'SPECHUMD', NF90_DOUBLE, (/dimCells,dimPLev,dimTime/), vSPECHUMD) )
      call check( nf90_def_var(ncid_out, 'RH',       NF90_DOUBLE, (/dimCells,dimPLev,dimTime/), vRH) )

      call check( nf90_def_var(ncid_out, 'TT_SFC',       NF90_DOUBLE, (/dimCells,dimTime/), vTTsfc) )
      call check( nf90_def_var(ncid_out, 'UU_SFC',       NF90_DOUBLE, (/dimCells,dimTime/), vUUsfc) )
      call check( nf90_def_var(ncid_out, 'VV_SFC',       NF90_DOUBLE, (/dimCells,dimTime/), vVVsfc) )
      call check( nf90_def_var(ncid_out, 'SPECHUMD_SFC', NF90_DOUBLE, (/dimCells,dimTime/), vSPECHUMDsfc) )
      call check( nf90_def_var(ncid_out, 'RH_SFC',       NF90_DOUBLE, (/dimCells,dimTime/), vRHsfc) )

      call check( nf90_def_var(ncid_out, 'PSFC',     NF90_DOUBLE, (/dimCells,dimTime/), vPSFC) )
      call check( nf90_def_var(ncid_out, 'PMSL',     NF90_DOUBLE, (/dimCells,dimTime/), vPMSL) )
      call check( nf90_def_var(ncid_out, 'SKINTEMP', NF90_DOUBLE, (/dimCells,dimTime/), vSKINTEMP) )
      call check( nf90_def_var(ncid_out, 'SOILHGT',  NF90_DOUBLE, (/dimCells,dimTime/), vSOILHGT) )
      call check( nf90_def_var(ncid_out, 'LANDSEA',  NF90_DOUBLE, (/dimCells,dimTime/), vLANDSEA) )
      call check( nf90_def_var(ncid_out, 'SST',      NF90_DOUBLE, (/dimCells,dimTime/), vSST) )
      call check( nf90_def_var(ncid_out, 'SNOW',     NF90_DOUBLE, (/dimCells,dimTime/), vSNOW) )
      call check( nf90_def_var(ncid_out, 'SEAICE',   NF90_DOUBLE, (/dimCells,dimTime/), vSEAICE) )

      do k = 1, 4
         call check( nf90_def_var(ncid_out, trim(soilnames_sm(k)), NF90_DOUBLE, (/dimCells,dimTime/), vSM(k)) )
         call check( nf90_def_var(ncid_out, trim(soilnames_st(k)), NF90_DOUBLE, (/dimCells,dimTime/), vST(k)) )
      end do

      call check( nf90_enddef(ncid_out) )

      call check( nf90_put_var(ncid_out, vLat, latCell) )
      call check( nf90_put_var(ncid_out, vLon, lonCell) )
      call check( nf90_put_var(ncid_out, vIdx, indexToCellID) )

      call check( nf90_put_var(ncid_out, vTT,       tt_plev,       start=(/1,1,1/), count=(/nCells,N_PLEVELS,1/)) )
      call check( nf90_put_var(ncid_out, vUU,       uu_plev,       start=(/1,1,1/), count=(/nCells,N_PLEVELS,1/)) )
      call check( nf90_put_var(ncid_out, vVV,       vv_plev,       start=(/1,1,1/), count=(/nCells,N_PLEVELS,1/)) )
      call check( nf90_put_var(ncid_out, vGHT,      ght_plev,      start=(/1,1,1/), count=(/nCells,N_PLEVELS,1/)) )
      call check( nf90_put_var(ncid_out, vSPECHUMD, spechumd_plev, start=(/1,1,1/), count=(/nCells,N_PLEVELS,1/)) )
      call check( nf90_put_var(ncid_out, vRH,       rh_plev,       start=(/1,1,1/), count=(/nCells,N_PLEVELS,1/)) )

      call check( nf90_put_var(ncid_out, vTTsfc,       t2m,  start=(/1,1/), count=(/nCells,1/)) )
      call check( nf90_put_var(ncid_out, vUUsfc,       u10,  start=(/1,1/), count=(/nCells,1/)) )
      call check( nf90_put_var(ncid_out, vVVsfc,       v10,  start=(/1,1/), count=(/nCells,1/)) )
      call check( nf90_put_var(ncid_out, vSPECHUMDsfc, q2,   start=(/1,1/), count=(/nCells,1/)) )
      call check( nf90_put_var(ncid_out, vRHsfc,       rh2m, start=(/1,1/), count=(/nCells,1/)) )

      call check( nf90_put_var(ncid_out, vPSFC,     psfc,     start=(/1,1/), count=(/nCells,1/)) )
      call check( nf90_put_var(ncid_out, vPMSL,     pmsl,     start=(/1,1/), count=(/nCells,1/)) )
      call check( nf90_put_var(ncid_out, vSKINTEMP, skintemp, start=(/1,1/), count=(/nCells,1/)) )
      call check( nf90_put_var(ncid_out, vSOILHGT,  soilhgt,  start=(/1,1/), count=(/nCells,1/)) )
      call check( nf90_put_var(ncid_out, vLANDSEA,  landsea,  start=(/1,1/), count=(/nCells,1/)) )
      call check( nf90_put_var(ncid_out, vSST,      sst,      start=(/1,1/), count=(/nCells,1/)) )
      call check( nf90_put_var(ncid_out, vSNOW,     snow,     start=(/1,1/), count=(/nCells,1/)) )
      call check( nf90_put_var(ncid_out, vSEAICE,   seaice,   start=(/1,1/), count=(/nCells,1/)) )

      do k = 1, 4
         call check( nf90_put_var(ncid_out, vSM(k), smois(k,:), start=(/1,1/), count=(/nCells,1/)) )
         call check( nf90_put_var(ncid_out, vST(k), tslb(k,:),  start=(/1,1/), count=(/nCells,1/)) )
      end do

      call check( nf90_close(ncid_out) )

   end subroutine write_output

end program extract_fields
