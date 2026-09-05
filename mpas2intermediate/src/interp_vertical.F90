! ============================================================================
! Rotinas de interpolacao vertical (niveis de modelo -> pressao fixa)
! extraidas e adaptadas de:
!
!   MPAS-Model/src/core_atmosphere/diagnostics/mpas_isobaric_diagnostics.F
!   subroutine interp_tofixed_pressure (linha ~1005)
!   subroutine compute_slp             (linha ~1094)
!
! Sao as MESMAS rotinas que o MPAS usa internamente para gerar os campos
! isobaricos do stream 'diagnostics' (height_500hPa, temperature_500hPa,
! etc.). Reaproveitamos aqui, em vez de escrever um metodo de interpolacao
! proprio, para garantir consistencia numerica com o que o proprio MPAS ja
! valida em producao.
!
! Adaptacoes em relacao ao original:
!   - mpas_log_write(...) trocado por write(0,*) (stderr), pois este
!     programa nao linka o framework do MPAS.
!   - Sem outras mudancas de logica/formula.
! ============================================================================

module interp_vertical

   use mpas_kind_types, only : RKIND

   implicit none
   private

   public :: interp_tofixed_pressure
   public :: compute_slp

   contains

   ! -------------------------------------------------------------------
   ! interp_tofixed_pressure
   !
   ! Interpola linearmente em pressao (nao em log-p) de nlev_in niveis de
   ! modelo (pressao variavel por coluna) para nlev_out niveis de pressao
   ! fixa (podem tambem variar por coluna em pres_out, mas tipicamente sao
   ! os mesmos valores repetidos em todas as colunas).
   !
   ! Extrapolacao:
   !   - acima do topo do dado de entrada (pres_out < pres_in(1)): reduz o
   !     valor proporcionalmente a razao de pressao (nao e clamping puro).
   !   - abaixo do nivel mais baixo do dado de entrada (pres_out >
   !     pres_in(nlev_in)): persistencia constante (repete o valor do
   !     nivel mais baixo), sem lapse-rate.
   !
   ! Fonte: mpas_isobaric_diagnostics.F:1005-1091 (identico, exceto logging)
   ! -------------------------------------------------------------------
   subroutine interp_tofixed_pressure(ncol,nlev_in,nlev_out,pres_in,field_in,pres_out,field_out)

      implicit none

      integer,intent(in):: ncol,nlev_in,nlev_out

      real(kind=RKIND),intent(in),dimension(ncol,nlev_in) :: pres_in,field_in
      real(kind=RKIND),intent(in),dimension(ncol,nlev_out):: pres_out

      real(kind=RKIND),intent(out),dimension(ncol,nlev_out):: field_out

      integer:: icol,k,kk
      integer:: kkstart,kount
      integer,dimension(ncol):: kupper

      real(kind=RKIND):: dpl,dpu

      do icol = 1, ncol
         kupper(icol) = 1
      enddo

      do k = 1, nlev_out

         kkstart = nlev_in
         do icol = 1, ncol
            kkstart = min0(kkstart,kupper(icol))
         enddo
         kount = 0

         do kk = kkstart, nlev_in-1
            do icol = 1, ncol
               if(pres_out(icol,k).gt.pres_in(icol,kk).and.pres_out(icol,k).le.pres_in(icol,kk+1)) then
                  kupper(icol) = kk
                  kount = kount + 1
               endif
            enddo

            if(kount.eq.ncol) then
               do icol = 1, ncol
                  dpu = pres_out(icol,k) - pres_in(icol,kupper(icol))
                  dpl = pres_in(icol,kupper(icol)+1) - pres_out(icol,k)
                  field_out(icol,k) = (field_in(icol,kupper(icol))*dpl &
                                    + field_in(icol,kupper(icol)+1)*dpu)/(dpl + dpu)
               end do
               goto 35
             end if
         enddo

         do icol = 1, ncol
            if(pres_out(icol,k) .lt. pres_in(icol,1)) then
               field_out(icol,k) = field_in(icol,1)*pres_out(icol,k)/pres_in(icol,1)
            elseif(pres_out(icol,k) .gt. pres_in(icol,nlev_in)) then
               field_out(icol,k) = field_in(icol,nlev_in)
            else
               dpu = pres_out(icol,k) - pres_in(icol,kupper(icol))
               dpl = pres_in(icol,kupper(icol)+1) - pres_out(icol,k)
               field_out(icol,k) = (field_in(icol,kupper(icol))*dpl &
                                 + field_in(icol,kupper(icol)+1)*dpu)/(dpl + dpu)
            endif
         enddo

      35 continue

      enddo

   end subroutine interp_tofixed_pressure


   ! -------------------------------------------------------------------
   ! compute_slp
   !
   ! Reducao da pressao de superficie ao nivel do mar (PMSL), metodo
   ! classico MM5/WRF (extrapolacao a partir da temperatura ~100 hPa
   ! acima da superficie, com a correcao MM5 para colunas muito quentes).
   !
   ! p, t: dimensao (nlev_in, ncol), pressao crescente com o indice
   !       (nivel 1 = mais proximo da superficie)
   ! height: dimensao (nlev_in+1, ncol) -- alturas de interface
   ! scalars(index_qv,:,:): razao de mistura de vapor d'agua (kg/kg)
   !
   ! Fonte: mpas_isobaric_diagnostics.F:1094-1227 (identico, exceto logging)
   ! -------------------------------------------------------------------
   subroutine compute_slp(ncol,nlev_in,nscalars,t,height,p,index_qv,scalars,slp)

      implicit none

      integer, intent(in) :: ncol, nlev_in, nscalars

      real(kind=RKIND), intent(in), dimension(nlev_in,ncol) :: p,t
      real(kind=RKIND), intent(in), dimension(nlev_in+1,ncol) :: height
      integer, intent(in) :: index_qv
      real(kind=RKIND), intent(in), dimension(nscalars,nlev_in,ncol) :: scalars

      real(kind=RKIND), intent(out), dimension(ncol) :: slp

      integer :: icol, k, kcount
      integer :: klo, khi

      real(kind=RKIND) :: gamma, rr, grav
      parameter (rr=287.0_RKIND, grav=9.80616_RKIND, gamma=0.0065_RKIND)

      real(kind=RKIND) :: tc, pconst
      parameter (tc=273.16_RKIND+17.5_RKIND, pconst=100._RKIND)

      logical, parameter :: mm5_test = .true.

      integer, dimension(:), allocatable :: level
      real(kind=RKIND), dimension(:), allocatable :: t_surf, t_msl
      real(kind=RKIND) :: plo , phi , tlo, thi , zlo , zhi
      real(kind=RKIND) :: p_at_pconst , t_at_pconst , z_at_pconst, z_half_lowest

      logical :: l1, l2, l3, found

      allocate(level(ncol))
      allocate(t_surf(ncol))
      allocate(t_msl(ncol))

      do icol = 1 , ncol
         level(icol) = -1

         k = 1
         found = .false.
         do while ( (.not. found) .and. (k.le.nlev_in))
               if ( p(k,icol) .lt. p(1,icol)-pconst ) then
                  level(icol) = k
                  found = .true.
               end if
               k = k+1
         end do

         if ( level(icol) .eq. -1 ) then
            write(0,*) 'compute_slp: troubles finding level ', pconst, ' Pa above ground at column ', icol
            write(0,*) 'compute_slp: surface pressure = ', p(1,icol), ' Pa -- MSLP will not be computed'
            slp(:) = 0.0_RKIND
            return
         end if

      end do

      do icol = 1 , ncol

         klo = max ( level(icol) - 1 , 1      )
         khi = min ( klo + 1        , nlev_in - 1 )

         if ( klo .eq. khi ) then
            write(0,*) 'compute_slp: trapping levels are weird at column ', icol, ' klo=', klo, ' khi=', khi
            slp(:) = 0.0_RKIND
            return
         end if

         plo = p(klo,icol)
         phi = p(khi,icol)
         tlo = t(klo,icol) * (1._RKIND + 0.608_RKIND * scalars(index_qv,klo,icol))
         thi = t(khi,icol) * (1._RKIND + 0.608_RKIND * scalars(index_qv,khi,icol))
         zlo = 0.5_RKIND*(height(klo,icol)+height(klo+1,icol))
         zhi = 0.5_RKIND*(height(khi,icol)+height(khi+1,icol))

         p_at_pconst = p(1,icol) - pconst
         t_at_pconst = thi-(thi-tlo)*log(p_at_pconst/phi)*log(plo/phi)
         z_at_pconst = zhi-(zhi-zlo)*log(p_at_pconst/phi)*log(plo/phi)

         t_surf(icol) = t_at_pconst*(p(1,icol)/p_at_pconst)**(gamma*rr/grav)
         t_msl(icol) = t_at_pconst+gamma*z_at_pconst

      end do

      if ( mm5_test ) then
         kcount = 0
         do icol = 1 , ncol
               l1 = t_msl(icol) .lt. tc
               l2 = t_surf(icol) .le. tc
               l3 = .not. l1
               if ( l2 .and. l3 ) then
                  t_msl(icol) = tc
               else
                  t_msl(icol) = tc - 0.005_RKIND*(t_surf(icol)-tc)**2
                  kcount = kcount+1
               end if
         end do
      end if

      do icol = 1 , ncol
         z_half_lowest=0.5_RKIND*(height(1,icol)+height(2,icol))
         slp(icol) = p(1,icol) * exp((2._RKIND*grav*z_half_lowest)/ &
                                   (rr*(t_msl(icol)+t_surf(icol))))
      end do

      deallocate(level)
      deallocate(t_surf)
      deallocate(t_msl)

   end subroutine compute_slp

end module interp_vertical
