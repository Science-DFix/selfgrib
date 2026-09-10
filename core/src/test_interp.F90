! Programa de VALIDACAO (nao e ainda o extrator final).
!
! Le os campos nativos (55 niveis de modelo) de um arquivo MPAS
! (history.nc ou o SouthAmerica.region.nc, que tem os mesmos campos
! copiados), calcula temperatura a partir de theta+pressure, e interpola
! para a lista de 55 niveis de pressao fixa definida em pressure_levels.F90,
! usando a mesma rotina que o MPAS usa internamente (interp_tofixed_pressure).
!
! Objetivo: confirmar visualmente que a interpolacao produz perfis
! fisicamente sensatos (temperatura decrescendo com a altura, etc.) antes de
! construir o escritor do formato binario intermediario do WPS.
!
! Uso: test_interp <arquivo.nc> <indice_da_celula_de_teste (1-based)>

program test_interp

   use mpas_kind_types,  only : RKIND
   use pressure_levels,  only : N_PLEVELS, plevels_hPa
   use interp_vertical,  only : interp_tofixed_pressure
   use netcdf

   implicit none

   character(len=1024) :: filename
   character(len=16)   :: arg2
   integer :: itest

   integer :: ncid, dimid, varid, ierr
   integer :: nCells, nVertLevels

   real(kind=RKIND), allocatable :: pressure(:,:)   ! (nVertLevels, nCells) -- ordem netCDF/Fortran: dim de variacao mais rapida primeiro
   real(kind=RKIND), allocatable :: theta(:,:)
   real(kind=RKIND), allocatable :: relhum(:,:)
   real(kind=RKIND), allocatable :: uzonal(:,:)
   real(kind=RKIND), allocatable :: umerid(:,:)
   real(kind=RKIND), allocatable :: zgrid(:,:)       ! (nVertLevels+1, nCells)
   real(kind=RKIND), allocatable :: temperature(:,:)
   real(kind=RKIND), allocatable :: height_mass(:,:) ! altura no nivel de massa (media das 2 interfaces)

   real(kind=RKIND), allocatable :: press_in(:,:), field_in(:,:), press_out(:,:), field_out(:,:)

   integer :: k, kk
   real(kind=RKIND), parameter :: P0 = 100000.0_RKIND      ! Pa
   real(kind=RKIND), parameter :: RCP = 0.285714_RKIND      ! Rd/cp

   if (command_argument_count() < 1) then
      write(0,*) 'Uso: test_interp <arquivo.nc> [indice_celula_teste]'
      stop 1
   end if
   call get_command_argument(1, filename)
   itest = 1
   if (command_argument_count() >= 2) then
      call get_command_argument(2, arg2)
      read(arg2,*) itest
   end if

   call check( nf90_open(trim(filename), NF90_NOWRITE, ncid) )

   call check( nf90_inq_dimid(ncid, 'nCells', dimid) )
   call check( nf90_inquire_dimension(ncid, dimid, len=nCells) )
   call check( nf90_inq_dimid(ncid, 'nVertLevels', dimid) )
   call check( nf90_inquire_dimension(ncid, dimid, len=nVertLevels) )

   write(0,*) 'nCells = ', nCells, '  nVertLevels = ', nVertLevels

   allocate(pressure(nVertLevels, nCells))
   allocate(theta(nVertLevels, nCells))
   allocate(relhum(nVertLevels, nCells))
   allocate(uzonal(nVertLevels, nCells))
   allocate(umerid(nVertLevels, nCells))
   allocate(zgrid(nVertLevels+1, nCells))
   allocate(temperature(nVertLevels, nCells))
   allocate(height_mass(nVertLevels, nCells))

   call read_var3d(ncid, 'pressure', pressure, nVertLevels, nCells)
   call read_var3d(ncid, 'theta', theta, nVertLevels, nCells)
   call read_var3d(ncid, 'relhum', relhum, nVertLevels, nCells)
   call read_var3d(ncid, 'uReconstructZonal', uzonal, nVertLevels, nCells)
   call read_var3d(ncid, 'uReconstructMeridional', umerid, nVertLevels, nCells)
   call read_var2d(ncid, 'zgrid', zgrid, nVertLevels+1, nCells)  ! sem dimensao Time

   call check( nf90_close(ncid) )

   ! Temperatura a partir de theta + pressao (pressure em Pa aqui)
   do k = 1, nVertLevels
      temperature(k,:) = theta(k,:) * (pressure(k,:)/P0)**RCP
      height_mass(k,:) = 0.5_RKIND*(zgrid(k,:) + zgrid(k+1,:))
   end do

   write(0,*) '--- perfil bruto (nativo, k=1 = superficie) na celula ', itest, ' ---'
   do k = 1, nVertLevels
      write(0,'(I3,3X,F9.2,A,3X,F7.2,A,3X,F7.2,A,3X,F8.2,A)') &
           k, pressure(k,itest)/100.0_RKIND, ' hPa', temperature(k,itest), ' K', &
           relhum(k,itest), ' %', height_mass(k,itest), ' m'
   end do

   ! Monta press_in/field_in COM A INVERSAO DE INDICE exigida por
   ! interp_tofixed_pressure (indice 1 = topo/menor pressao). Pressao em hPa.
   allocate(press_in(nCells, nVertLevels))
   allocate(field_in(nCells, nVertLevels))
   allocate(press_out(nCells, N_PLEVELS))
   allocate(field_out(nCells, N_PLEVELS))

   do k = 1, nVertLevels
      kk = nVertLevels + 1 - k
      press_in(:, kk) = pressure(k,:) / 100.0_RKIND   ! Pa -> hPa
   end do

   do k = 1, N_PLEVELS
      press_out(:, k) = plevels_hPa(k)
   end do

   write(0,*) ''
   write(0,*) '--- Temperatura interpolada (55 niveis de pressao fixa) na celula ', itest, ' ---'
   do k = 1, nVertLevels
      kk = nVertLevels + 1 - k
      field_in(:, kk) = temperature(k,:)
   end do
   call interp_tofixed_pressure(nCells, nVertLevels, N_PLEVELS, press_in, field_in, press_out, field_out)
   do k = 1, N_PLEVELS
      write(0,'(F9.2,A,3X,F7.2,A)') plevels_hPa(k), ' hPa', field_out(itest,k), ' K'
   end do

   write(0,*) ''
   write(0,*) '--- Umidade relativa interpolada na celula ', itest, ' ---'
   do k = 1, nVertLevels
      kk = nVertLevels + 1 - k
      field_in(:, kk) = relhum(k,:)
   end do
   call interp_tofixed_pressure(nCells, nVertLevels, N_PLEVELS, press_in, field_in, press_out, field_out)
   do k = 1, N_PLEVELS
      write(0,'(F9.2,A,3X,F7.2,A)') plevels_hPa(k), ' hPa', field_out(itest,k), ' %'
   end do

   write(0,*) ''
   write(0,*) 'OK -- interpolacao executada sem erros.'

contains

   subroutine check(status)
      integer, intent(in) :: status
      if (status /= nf90_noerr) then
         write(0,*) 'Erro NetCDF: ', trim(nf90_strerror(status))
         stop 1
      end if
   end subroutine check

   subroutine read_var3d(ncid_in, varname, arr, nz, nc)
      integer, intent(in) :: ncid_in, nz, nc
      character(len=*), intent(in) :: varname
      real(kind=RKIND), intent(out) :: arr(nz, nc)
      integer :: vid
      call check( nf90_inq_varid(ncid_in, varname, vid) )
      call check( nf90_get_var(ncid_in, vid, arr, start=(/1,1,1/), count=(/nz,nc,1/)) )
   end subroutine read_var3d

   ! Para variaveis SEM dimensao Time (ex: zgrid, campo de malha estatico)
   subroutine read_var2d(ncid_in, varname, arr, nz, nc)
      integer, intent(in) :: ncid_in, nz, nc
      character(len=*), intent(in) :: varname
      real(kind=RKIND), intent(out) :: arr(nz, nc)
      integer :: vid
      call check( nf90_inq_varid(ncid_in, varname, vid) )
      call check( nf90_get_var(ncid_in, vid, arr, start=(/1,1/), count=(/nz,nc/)) )
   end subroutine read_var2d

end program test_interp
