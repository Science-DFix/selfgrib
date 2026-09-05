! pack_intermediate
!
! Ultimo estagio do pipeline "ungrib para MPAS":
!
!   extract_fields (malha nativa, interp. vertical)
!        -> convert_mpas (remapeamento horizontal p/ lat-lon: 'latlon.nc')
!        -> pack_intermediate  <-- este programa
!        -> arquivo binario intermediario PREFIX:YYYY-MM-DD_HH
!        -> init_atmosphere_model (config_init_case=7/9), sem nenhum patch
!
! Le o 'latlon.nc' produzido pelo convert_mpas (dimensoes 'longitude' e
! 'latitude', ja em GRAUS -- confirmado em convert_mpas/src/remapper.F90,
! linha ~837: array1r = lats*rad2deg) e escreve, para cada campo/nivel, um
! registro no formato binario intermediario do WPS (write_intermediate.F90).
!
! Uso: pack_intermediate <latlon.nc> <hdate 'YYYY-MM-DD_HH:MM:SS'> <prefixo_saida>
!
! Gera o arquivo <prefixo_saida>:<hdate ate a hora>, ex. 'MPAS:2026-01-02_00'

program pack_intermediate

   use pressure_levels,   only : N_PLEVELS, plevels_hPa, LEVEL_SFC_PA, LEVEL_SEALVL_PA
   use write_intermediate, only : write_intermediate_latlon_field
   use netcdf

   implicit none

   character(len=1024) :: latlonfile, prefix, outfile
   character(len=32)   :: hdate_arg
   character(len=24)   :: hdate24

   integer :: ncid, dimid, k
   integer :: nlon, nlat
   real, allocatable :: lats(:), lons(:)
   real :: startlat, startlon, deltalat, deltalon

   real, allocatable :: slab2d(:,:)          ! (nlon, nlat)
   real, allocatable :: slab3d(:,:,:)        ! (nlon, nlat, nlev)   -- campos em niveis de pressao

   logical :: first_write
   character(len=32), parameter :: SOURCE = 'MPAS-A (native, regridded)'

   if (command_argument_count() < 3) then
      write(0,*) 'Uso: pack_intermediate <latlon.nc> <hdate YYYY-MM-DD_HH:MM:SS> <prefixo_saida>'
      stop 1
   end if
   call get_command_argument(1, latlonfile)
   call get_command_argument(2, hdate_arg)
   call get_command_argument(3, prefix)

   hdate24 = adjustl(hdate_arg)
   ! Nome do arquivo final: PREFIXO:AAAA-MM-DD_HH (mesma convencao do
   ! config_met_prefix do MPAS / prefix do ungrib)
   outfile = trim(prefix)//':'//hdate24(1:13)

   call check( nf90_open(trim(latlonfile), NF90_NOWRITE, ncid) )

   call check( nf90_inq_dimid(ncid, 'longitude', dimid) )
   call check( nf90_inquire_dimension(ncid, dimid, len=nlon) )
   call check( nf90_inq_dimid(ncid, 'latitude', dimid) )
   call check( nf90_inquire_dimension(ncid, dimid, len=nlat) )

   write(0,*) 'nlon = ', nlon, '  nlat = ', nlat

   allocate(lats(nlat), lons(nlon))
   call read1d(ncid, 'latitude', lats, nlat)
   call read1d(ncid, 'longitude', lons, nlon)

   startlat = lats(1)
   startlon = lons(1)
   deltalat = lats(2) - lats(1)
   deltalon = lons(2) - lons(1)

   write(0,*) 'startlat=', startlat, ' startlon=', startlon, &
              ' deltalat=', deltalat, ' deltalon=', deltalon

   allocate(slab2d(nlon,nlat))
   allocate(slab3d(nlon,nlat,N_PLEVELS))

   first_write = .true.

   !--------------------------------------------------------------------
   ! Campos em niveis de pressao fixa (3D)
   !--------------------------------------------------------------------
   call write_plevels('TT',       'K                        ', 'Temperature                                  ')
   call write_plevels('UU',       'm s-1                    ', 'Zonal Wind                                   ')
   call write_plevels('VV',       'm s-1                    ', 'Meridional Wind                              ')
   call write_plevels('GHT',      'm                        ', 'Geopotential Height                          ')
   call write_plevels('SPECHUMD', 'kg kg-1                  ', 'Specific Humidity                            ')
   call write_plevels('RH',       '%                        ', 'Relative Humidity                            ')

   !--------------------------------------------------------------------
   ! Pseudo-nivel de superficie (200100 Pa) -- TT/UU/VV/SPECHUMD "at 2/10 m"
   !--------------------------------------------------------------------
   call write_sfc('TT_SFC',       'TT',       'K                        ', 'Temperature                       at 2 m     ')
   call write_sfc('UU_SFC',       'UU',       'm s-1                    ', 'Zonal Wind                        at 10 m    ')
   call write_sfc('VV_SFC',       'VV',       'm s-1                    ', 'Meridional Wind                   at 10 m    ')
   call write_sfc('SPECHUMD_SFC', 'SPECHUMD', 'kg kg-1                  ', 'Specific Humidity                 at 2 m     ')
   call write_sfc('RH_SFC',       'RH',       '%                        ', 'Relative Humidity                 at 2 m     ')

   !--------------------------------------------------------------------
   ! Campos de superficie (nivel 200100, exceto PMSL em 201300)
   !--------------------------------------------------------------------
   call write_sfc('PSFC',     'PSFC',     'Pa                       ', 'Surface Pressure                             ')
   call write_sfc('SKINTEMP', 'SKINTEMP', 'K                        ', 'Surface (skin) Temperature                   ')
   call write_sfc('SOILHGT',  'SOILHGT',  'm                        ', 'Terrain field of source analysis             ')
   call write_sfc('LANDSEA',  'LANDSEA',  'proprtn                  ', 'Land/Sea flag (1=land, 0=sea)                ')
   call write_sfc('SST',      'SST',      'K                        ', 'Sea-Surface Temperature                      ')
   call write_sfc('SNOW',     'SNOW',     'kg m-2                   ', 'Water equivalent snow depth                  ')
   call write_sfc('SEAICE',   'SEAICE',   'proprtn                  ', 'Ice flag                                     ')

   do k = 1, 4
      call write_sfc(soilname_sm(k), soilname_sm(k), 'm3 m-3                   ', soildesc_sm(k))
      call write_sfc(soilname_st(k), soilname_st(k), 'K                        ', soildesc_st(k))
   end do

   !--------------------------------------------------------------------
   ! PMSL -- pseudo-nivel "nivel do mar" (201300 Pa)
   !--------------------------------------------------------------------
   call read2d(ncid, 'PMSL', slab2d, nlon, nlat)
   call write_intermediate_latlon_field(trim(outfile), .not. first_write, hdate24, 'PMSL     ', &
        'Pa                       ', 'Sea-level Pressure                           ', &
        real(LEVEL_SEALVL_PA), nlon, nlat, startlat, startlon, deltalat, deltalon, &
        SOURCE, .true., slab2d)
   first_write = .false.

   call check( nf90_close(ncid) )

   write(0,*) 'Arquivo intermediario escrito: ', trim(outfile)

contains

   function soilname_sm(k) result(nm)
      integer, intent(in) :: k
      character(len=9) :: nm
      select case (k)
      case (1); nm = 'SM000010'
      case (2); nm = 'SM010040'
      case (3); nm = 'SM040100'
      case (4); nm = 'SM100200'
      end select
   end function soilname_sm

   function soilname_st(k) result(nm)
      integer, intent(in) :: k
      character(len=9) :: nm
      select case (k)
      case (1); nm = 'ST000010'
      case (2); nm = 'ST010040'
      case (3); nm = 'ST040100'
      case (4); nm = 'ST100200'
      end select
   end function soilname_st

   function soildesc_sm(k) result(ds)
      integer, intent(in) :: k
      character(len=46) :: ds
      select case (k)
      case (1); ds = 'Soil Moist 0-10 cm below grn layer (Noah)'
      case (2); ds = 'Soil Moist 10-40 cm below grn layer (Noah)'
      case (3); ds = 'Soil Moist 40-100 cm below grn layer (Noah)'
      case (4); ds = 'Soil Moist 100-200 cm below grn layer (Noah)'
      end select
   end function soildesc_sm

   function soildesc_st(k) result(ds)
      integer, intent(in) :: k
      character(len=46) :: ds
      select case (k)
      case (1); ds = 'T 0-10 cm below ground layer (Noah)'
      case (2); ds = 'T 10-40 cm below ground layer (Noah)'
      case (3); ds = 'T 40-100 cm below ground layer (Noah)'
      case (4); ds = 'T 100-200 cm below ground layer (Noah)'
      end select
   end function soildesc_st

   subroutine write_plevels(varname, units, desc)
      character(len=*), intent(in) :: varname, units, desc
      integer :: vid, kk
      call check( nf90_inq_varid(ncid, trim(varname), vid) )
      call check( nf90_get_var(ncid, vid, slab3d, start=(/1,1,1,1/), count=(/nlon,nlat,N_PLEVELS,1/)) )
      do kk = 1, N_PLEVELS
         call write_intermediate_latlon_field(trim(outfile), .not. first_write, hdate24, varname, &
              units, desc, real(plevels_hPa(kk)*100.0), nlon, nlat, &
              startlat, startlon, deltalat, deltalon, SOURCE, .true., slab3d(:,:,kk))
         first_write = .false.
      end do
   end subroutine write_plevels

   subroutine write_sfc(ncvarname, wpsfield, units, desc)
      character(len=*), intent(in) :: ncvarname, wpsfield, units, desc
      integer :: vid
      call check( nf90_inq_varid(ncid, trim(ncvarname), vid) )
      call check( nf90_get_var(ncid, vid, slab2d, start=(/1,1,1/), count=(/nlon,nlat,1/)) )
      call write_intermediate_latlon_field(trim(outfile), .not. first_write, hdate24, wpsfield, &
           units, desc, real(LEVEL_SFC_PA), nlon, nlat, &
           startlat, startlon, deltalat, deltalon, SOURCE, .true., slab2d)
      first_write = .false.
   end subroutine write_sfc

   subroutine check(status)
      integer, intent(in) :: status
      if (status /= nf90_noerr) then
         write(0,*) 'Erro NetCDF: ', trim(nf90_strerror(status))
         stop 1
      end if
   end subroutine check

   subroutine read1d(ncid_in, varname, arr, n)
      integer, intent(in) :: ncid_in, n
      character(len=*), intent(in) :: varname
      real, intent(out) :: arr(n)
      integer :: vid
      call check( nf90_inq_varid(ncid_in, varname, vid) )
      call check( nf90_get_var(ncid_in, vid, arr) )
   end subroutine read1d

   subroutine read2d(ncid_in, varname, arr, nx, ny)
      integer, intent(in) :: ncid_in, nx, ny
      character(len=*), intent(in) :: varname
      real, intent(out) :: arr(nx,ny)
      integer :: vid
      call check( nf90_inq_varid(ncid_in, varname, vid) )
      call check( nf90_get_var(ncid_in, vid, arr, start=(/1,1,1/), count=(/nx,ny,1/)) )
   end subroutine read2d

end program pack_intermediate
