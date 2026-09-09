! Fase 3 do plano de interpolacao nativa Voronoi (ver
! /home/dvar/.claude/plans/cheerful-knitting-platypus.md). Extraido
! literalmente de MPAS-Model/src/core_init_atmosphere/mpas_init_atm_cases.F
! (versao real de producao, mpas-bundle-3.0.2, confirmada via
! CMakeCache.txt do build-mpich-single -- ver nota no plano), funcao
! LOCAL `vertical_interp` (linha ~6488 dessa versao) -- NAO e' a mesma
! rotina `interp_tofixed_pressure` de interp_vertical.F90 (essa e' usada
! so' na saida diagnostica isobarica diag.*.nc, caminho de codigo
! diferente). `vertical_interp` interpola linearmente em ALTURA (nao em
! pressao), ponto a ponto, com extrapolacao configuravel.
!
! Simplificacao deliberada em relacao ao original: o original monta um
! unico array por coluna concatenando os niveis de pressao fixos MAIS um
! registro de "pseudo-nivel de superficie" (vert_level==200100.0, mesma
! convencao WPS de pressure_levels.F90::LEVEL_SFC_PA), cuja coordenada e'
! forcada pra 99999.0 antes do sort -- efeito liquido: esse registro
! sempre cai no ultimo indice apos o sort e NUNCA e' usado como ponto de
! interpolacao ou extrapolacao (nem target_z alcanca 99999, nem o ramo
! "abaixo do primeiro ponto" o usa, ja que ele fica no topo do array
! ordenado) -- e' provadamente inerte pra este algoritmo. Como o
! extract_fields.F90 deste projeto ja mantem os campos de superficie
! (TTsfc/UUsfc/VVsfc/SPECHUMDsfc) em variaveis SEPARADAS dos niveis de
! pressao (nunca concatenados num unico array), simplesmente omitimos
! esse registro em vez de reproduzir o truque do 99999 -- resultado
! numerico identico, codigo mais simples.
module vinterp_native

    use mpas_kind_types, only : RKIND

    implicit none
    private

    public :: vertical_interp
    public :: interp_column_to_layers

    contains

    !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    ! vertical_interp
    !
    ! Porta literal da funcao local de mesmo nome em mpas_init_atm_cases.F
    ! (nao a versao do modulo init_atm_vinterp, que fica sombreada/nao-usada
    ! no original por conflito de nome local vs. use-associado -- ver nota
    ! no plano). zf(1,:) = coordenada (altura), zf(2,:) = valor do campo,
    ! JA ORDENADOS ascendente por zf(1,:) (chamador deve ordenar antes).
    !
    ! Parametro "order" do original nao e' reproduzido aqui: no
    ! codigo-fonte real ele e' recebido mas nunca usado no corpo da funcao
    ! (sempre interpolacao linear, independente do valor) -- e' sempre
    ! chamado com order=1 de qualquer forma.
    !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    real (kind=RKIND) function vertical_interp(target_z, nz, zf, extrap, ierr) result(val)

        implicit none

        real (kind=RKIND), intent(in) :: target_z
        integer, intent(in) :: nz
        real (kind=RKIND), dimension(2,nz), intent(in) :: zf
        integer, intent(in) :: extrap   ! 0=constante, 1=linear, 2=lapse-rate (-0.0065 K/m; so' no ramo abaixo do 1o ponto)
        integer, intent(out), optional :: ierr

        integer :: k, lm, lp
        real (kind=RKIND) :: wm, wp, slope

        if (present(ierr)) ierr = 0

        if (target_z < zf(1,1)) then
            if (extrap == 0) then
                val = zf(2,1)
            else if (extrap == 1) then
                slope = (zf(2,2) - zf(2,1)) / (zf(1,2) - zf(1,1))
                val = zf(2,1) + slope * (target_z - zf(1,1))
            else if (extrap == 2) then
                val = zf(2,1) - (target_z - zf(1,1)) * 0.0065_RKIND
            end if
            return
        end if

        if (target_z >= zf(1,nz)) then
            if (extrap == 0) then
                val = zf(2,nz)
            else if (extrap == 1) then
                slope = (zf(2,nz) - zf(2,nz-1)) / (zf(1,nz) - zf(1,nz-1))
                val = zf(2,nz) + slope * (target_z - zf(1,nz))
            else if (extrap == 2) then
                ! Mesmo erro fatal do original ("extrap_type == 2 not
                ! implemented for target_z >= zf(1,nz)") -- na pratica nao
                ! deve ocorrer aqui: target_z <= config_ztop (30000m) sempre,
                ! e o buffer de niveis de pressao (N_ALWAYS_EXTRAP, ver
                ! pressure_levels.F90) ja garante altura do topo do
                ! first-guess bem acima disso.
                if (present(ierr)) ierr = 1
                val = 0.0_RKIND
            end if
            return
        end if

        do k=1,nz-1
            if (target_z >= zf(1,k) .and. target_z < zf(1,k+1)) then
                lm = k
                lp = k+1
                wm = (zf(1,k+1) - target_z) / (zf(1,k+1) - zf(1,k))
                wp = (target_z - zf(1,k)) / (zf(1,k+1) - zf(1,k))
                exit
            end if
        end do

        val = wm*zf(2,lm) + wp*zf(2,lp)

    end function vertical_interp


    !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    ! interp_column_to_layers
    !
    ! Interpola uma coluna (nz pontos, coordenada z_col + valor field_col,
    ! em qualquer ordem) para os pontos-alvo target_z(1:n_out) usando
    ! vertical_interp. Ordena a coluna internamente (insertion sort --
    ! nz tipicamente ~61, desempenho irrelevante).
    !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    subroutine interp_column_to_layers(nz, z_col, field_col, n_out, target_z, extrap, field_out, ierr)

        implicit none

        integer, intent(in) :: nz, n_out
        real (kind=RKIND), dimension(nz), intent(in) :: z_col, field_col
        real (kind=RKIND), dimension(n_out), intent(in) :: target_z
        integer, intent(in) :: extrap
        real (kind=RKIND), dimension(n_out), intent(out) :: field_out
        integer, intent(out), optional :: ierr

        real (kind=RKIND), dimension(2,nz) :: sorted_arr
        integer :: i, j, k, ierr_k
        real (kind=RKIND) :: key1, key2

        sorted_arr(1,:) = z_col
        sorted_arr(2,:) = field_col

        ! Insertion sort ascendente por sorted_arr(1,:), mantendo o par.
        do i=2,nz
            key1 = sorted_arr(1,i)
            key2 = sorted_arr(2,i)
            j = i - 1
            do while (j >= 1)
                if (sorted_arr(1,j) <= key1) exit
                sorted_arr(1,j+1) = sorted_arr(1,j)
                sorted_arr(2,j+1) = sorted_arr(2,j)
                j = j - 1
            end do
            sorted_arr(1,j+1) = key1
            sorted_arr(2,j+1) = key2
        end do

        if (present(ierr)) ierr = 0
        do k=1,n_out
            field_out(k) = vertical_interp(target_z(k), nz, sorted_arr, extrap, ierr_k)
            if (ierr_k /= 0 .and. present(ierr)) ierr = ierr_k
        end do

    end subroutine interp_column_to_layers

end module vinterp_native
