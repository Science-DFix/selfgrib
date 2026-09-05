! write_intermediate
!
! Escreve um registro no formato binario intermediario do WPS, versao 5
! ('WP'), reproduzindo EXATAMENTE a sequencia de write() da subrotina
! output.F do ungrib (WPS/ungrib/src/output.F:220-247, ramo
! out_format(1:2)=='WP'), e compativel com a leitura em
! MPAS-Model/src/core_init_atmosphere/mpas_init_atm_read_met.F
! (subroutine read_next_met_field, branch version==5).
!
! ATENCAO: todos os campos numericos do registro sao SINGLE PRECISION
! (real32/kind=4) -- e o tipo declarado em met_data (mpas_init_atm_read_met.F,
! "real (kind=real32)"), NAO double precision. Usar double aqui quebraria a
! leitura silenciosamente (registros Fortran sequenciais tem tamanho fixo:
! um mismatch de kind desalinha a leitura de TODOS os campos seguintes).
!
! So implementamos aqui o caso de grade lat-lon regular (igrid=0), que e o
! que o convert_mpas produz (latitude/longitude regulares) -- e o mesmo tipo
! de grade que ungrib produz a partir de GRIB em lat-lon (ex. GFS 0.25deg).

module write_intermediate

   implicit none
   private

   public :: write_intermediate_latlon_field

   integer, parameter :: R32 = 4

   contains

   ! -------------------------------------------------------------------
   ! write_intermediate_latlon_field
   !
   ! filename    : caminho completo do arquivo de saida (ex.
   !               'MPAS:2026-01-02_00' -- mesma convencao PREFIX:HDATE do
   !               ungrib/config_met_prefix)
   ! append      : .true. para adicionar ao arquivo existente (varios campos
   !               por arquivo), .false. para (re)criar do zero
   ! hdate       : data no formato WPS, 'YYYY-MM-DD_HH:MM:SS' (24 caracteres,
   !               preenchido com espacos/zeros conforme necessario)
   ! field       : nome do campo (9 caracteres, ex. 'TT       ')
   ! units       : unidades (25 caracteres, ex. 'K                        ')
   ! desc        : descricao (46 caracteres) -- NAO pode ser todo espacos
   !               (ungrib usa desc==' ' como sinal de "no escrever este
   !               registro" na saida final, ver output.F:179)
   ! level_pa    : nivel vertical em Pa (100000.0 = 1000 hPa; usar
   !               LEVEL_SFC_PA/LEVEL_SEALVL_PA de pressure_levels.F90 para
   !               os pseudo-niveis de superficie/nivel-do-mar)
   ! nx, ny      : dimensoes da grade
   ! startlat/startlon : latitude/longitude (graus) do primeiro ponto da grade
   ! deltalat/deltalon : espacamento da grade (graus)
   ! field_source: fonte dos dados (32 caracteres, ex. 'MPAS-A x1.163842')
   ! is_wind_earth_rel : .true. se UU/VV sao relativos a Terra (padrao para
   !               grades lat-lon; so seria .false. em grades projetadas
   !               tipo Lambert onde o vento e relativo a grade)
   ! slab        : array (nx,ny) com os valores do campo
   ! -------------------------------------------------------------------
   subroutine write_intermediate_latlon_field(filename, append, hdate, field, units, desc, &
                                               level_pa, nx, ny, startlat, startlon, &
                                               deltalat, deltalon, field_source, &
                                               is_wind_earth_rel, slab)

      implicit none

      character(len=*), intent(in) :: filename
      logical, intent(in) :: append
      character(len=*), intent(in) :: hdate
      character(len=*), intent(in) :: field
      character(len=*), intent(in) :: units
      character(len=*), intent(in) :: desc
      real, intent(in) :: level_pa
      integer, intent(in) :: nx, ny
      real, intent(in) :: startlat, startlon, deltalat, deltalon
      character(len=*), intent(in) :: field_source
      logical, intent(in) :: is_wind_earth_rel
      real, intent(in) :: slab(nx,ny)

      integer, parameter :: iunit = 21

      character(len=24) :: hdate24
      character(len=32) :: source32
      character(len=9)  :: field9
      character(len=25) :: units25
      character(len=46) :: desc46
      character(len=8)  :: startloc

      real(kind=R32) :: r_xfcst, r_level, r_startlat, r_startlon, r_deltalat, r_deltalon, r_earth
      integer :: r_nx, r_ny, r_igrid
      logical :: l_grid_wind

      hdate24  = adjustl(hdate)
      source32 = adjustl(field_source)
      field9   = adjustl(field)
      units25  = adjustl(units)
      desc46   = adjustl(desc)
      startloc = 'SWCORNER'   ! (lat1,lon1) referem-se ao canto sudoeste da grade

      r_xfcst    = 0.0_R32
      r_level    = real(level_pa, kind=R32)
      r_startlat = real(startlat, kind=R32)
      r_startlon = real(startlon, kind=R32)
      r_deltalat = real(deltalat, kind=R32)
      r_deltalon = real(deltalon, kind=R32)
      ! Raio da esfera da propria malha MPAS-A (sphere_radius=6.371229e6 m,
      ! confirmado em SouthAmerica.region.nc e batendo com o EARTH_RADIUS
      ! usado nos arquivos intermediarios reais de producao, ex.
      ! /mnt/dados2/rodadas/MPAS-A/2025122800/met_data/FILE:2025-12-28_00,
      ! que usa 6371.229492 -- NAO usar o 6370.0 legado do WPS/ungrib.
      r_earth    = 6371.229_R32
      r_nx       = nx
      r_ny       = ny
      r_igrid    = 0            ! cylindrical equidistant (lat-lon)
      l_grid_wind = .not. is_wind_earth_rel   ! met_data%is_wind_grid_rel

      if (append) then
         open(unit=iunit, file=trim(filename), form='unformatted', &
              status='unknown', position='append')
      else
         open(unit=iunit, file=trim(filename), form='unformatted', &
              status='replace', position='rewind')
      end if

      write(iunit) 5

      write(iunit) hdate24, r_xfcst, source32, field9, units25, desc46, &
                   r_level, r_nx, r_ny, r_igrid

      ! bloco de projecao lat-lon (igrid==0), na mesma ordem de
      ! mpas_init_atm_read_met.F (startloc, startlat, startlon, deltalat,
      ! deltalon) seguido de r_earth (formato versao 5 inclui r_earth em
      ! todo tipo de projecao -- ver output.F:233-235)
      write(iunit) startloc, r_startlat, r_startlon, r_deltalat, r_deltalon, r_earth

      write(iunit) l_grid_wind

      write(iunit) real(slab, kind=R32)

      close(iunit)

   end subroutine write_intermediate_latlon_field

end module write_intermediate
