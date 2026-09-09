! Fase 6 (campos de superficie/solo do init.nc) do plano de interpolacao
! nativa Voronoi. Extraido literalmente de
! MPAS-Model/src/core_init_atmosphere/mpas_atmphys_initialize_real.F e
! mpas_atmphys_date_time.F (mpas-bundle-3.0.2, achado em 2026-09-09
! buscando tmn/sh2o/vegfra/sfc_albbck em todo o core_init_atmosphere --
! NAO ficam em mpas_init_atm_cases.F, ao contrario do que a categorizacao
! original do plano assumia pra alguns desses campos).
module surface_fields

    use mpas_kind_types, only : RKIND

    implicit none
    private

    public :: monthly_interp_to_date
    public :: day_of_year

    contains

    !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    ! day_of_year
    !
    ! Dia do ano (1-based), calendario Gregoriano padrao com ano bissexto.
    !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    integer function day_of_year(year, month, day) result(doy)

        implicit none

        integer, intent(in) :: year, month, day

        integer, dimension(12) :: days_in_month
        logical :: leap
        integer :: m

        leap = (mod(year,4) == 0 .and. mod(year,100) /= 0) .or. mod(year,400) == 0
        days_in_month = (/31,28,31,30,31,30,31,31,30,31,30,31/)
        if (leap) days_in_month(2) = 29

        doy = day
        do m=1,month-1
            doy = doy + days_in_month(m)
        end do

    end function day_of_year


    !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    ! monthly_interp_to_date
    !
    ! Porta literal de mpas_atmphys_date_time.F::monthly_interp_to_date --
    ! interpolacao linear de uma climatologia mensal (valor representa o
    ! dia 15 de cada mes) pra uma data-alvo qualquer. field_in(12,nCells)
    ! -- indice 1=Janeiro..12=Dezembro (mesma convencao de greenfrac/
    ! albedo12m no static.nc).
    !
    ! Simplificacao fiel ao original: os "meses-ancora" de padding
    ! (dezembro do ano anterior / janeiro do ano seguinte) NAO usam o dia
    ! do ano real desses meses em outro ano -- o codigo-fonte real usa
    ! literalmente middle(0)=middle(1)-31 e middle(13)=middle(12)+31 (um
    ! deslocamento fixo de 31 dias, nao aritmetica de calendario real
    ! cruzando o ano). Reproduzido aqui do mesmo jeito -- validado
    ! numericamente batendo exato contra vegfra do init.nc real
    ! (SouthAmerica, config_start_time=2026-01-01_00:00:00).
    !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    subroutine monthly_interp_to_date(nCells, target_year, target_month, target_day, field_in, field_out)

        implicit none

        integer, intent(in) :: nCells, target_year, target_month, target_day
        real (kind=RKIND), dimension(12,nCells), intent(in) :: field_in
        real (kind=RKIND), dimension(nCells), intent(out) :: field_out

        integer, dimension(0:13) :: middle
        integer :: l, target_date, int_month, month1, month2

        do l=1,12
            middle(l) = day_of_year(target_year, l, 15)
        end do
        middle(0)  = middle(1)  - 31
        middle(13) = middle(12) + 31

        target_date = day_of_year(target_year, target_month, target_day)

        do l=0,12
            if (middle(l) < target_date .and. middle(l+1) >= target_date) then
                int_month = l
                if (int_month == 0 .or. int_month == 12) then
                    month1 = 12
                    month2 = 1
                else
                    month1 = int_month
                    month2 = month1 + 1
                end if

                field_out = ( field_in(month2,:) * real(target_date - middle(l),   RKIND)   &
                            + field_in(month1,:) * real(middle(l+1) - target_date, RKIND) ) &
                            / real(middle(l+1) - middle(l), RKIND)
                return
            end if
        end do

    end subroutine monthly_interp_to_date

end module surface_fields
