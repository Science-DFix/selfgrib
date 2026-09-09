! Fase 4 do plano de interpolacao nativa Voronoi (ver
! /home/dvar/.claude/plans/cheerful-knitting-platypus.md, secao "Fase 4").
! Extraido literalmente de
! MPAS-Model/src/core_init_atmosphere/mpas_init_atm_cases.F (mpas-bundle-3.0.2,
! bloco config_met_interp, linhas ~4811-5001 dessa versao -- confirmada
! como o fonte real que gerou o binario de producao). Balanco hidrostatico,
! densidade/theta acoplados a metrica vertical, agua precipitavel, vento
! vertical diagnostico, pressao de superficie.
!
! Preserva DELIBERADAMENTE duas formulas distintas de rho_zz que aparecem
! no original (uma no calculo diagnostico inicial, outra no nivel 1 e na
! solucao hidrostatica iterativa) -- nao sao redundantes, ver comentarios
! inline. Nao "corrigir"/reconciliar sem validar contra o init.nc real
! primeiro.
module hydrostatic

    use mpas_kind_types, only : RKIND
    use mpas_constants, only : gravity, rgas, cp, rvord, cv, p0

    implicit none
    private

    public :: compute_hydrostatic_balance
    public :: compute_q2
    public :: convert_relhum_wrt_ice

    real (kind=RKIND), parameter :: t0b = 250.0_RKIND

    contains

    !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    ! compute_hydrostatic_balance
    !
    ! Entrada: pressure/t/qv ja na malha vertical nativa (saida da Fase 3,
    ! vinterp_native), zgrid/zz/zb/zb3/fzm/fzp/dzu/rdzw ja na malha vertical
    ! nativa (saida da Fase 2, vertical_grid), u ja como componente normal
    ! nas arestas (rotacionado pela Fase 3).
    !
    ! Saida: rho/theta/qv(passthrough)/precipw/w/ru/surface_pressure.
    ! "t" e' sobrescrito in-place: entra como temperatura, sai como THETA_M
    ! (potencial umida) -- mesma convencao do original. "pressure" tambem
    ! e' sobrescrito in-place pela solucao hidrostatica (niveis k=2..nz1).
    !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    subroutine compute_hydrostatic_balance(nCells, nEdges, maxEdges, nz1, nz, &
                                            nEdgesOnCell, edgesOnCell, cellsOnEdge, &
                                            zgrid, zz, zb, zb3, fzm, fzp, dzu, rdzw, &
                                            config_theta_adv_order, config_coef_3rd_order, &
                                            pressure, t, qv, u, &
                                            rho, theta, rho_base, theta_base, precipw, w, ru, surface_pressure)

        implicit none

        integer, intent(in) :: nCells, nEdges, maxEdges, nz1, nz
        integer, dimension(nCells), intent(in) :: nEdgesOnCell
        integer, dimension(maxEdges,nCells), intent(in) :: edgesOnCell
        integer, dimension(2,nEdges), intent(in) :: cellsOnEdge
        real (kind=RKIND), dimension(nz,nCells), intent(in) :: zgrid
        real (kind=RKIND), dimension(nz1,nCells), intent(in) :: zz
        real (kind=RKIND), dimension(nz,2,nEdges), intent(in) :: zb, zb3
        real (kind=RKIND), dimension(nz1), intent(in) :: fzm, fzp, dzu, rdzw
        integer, intent(in) :: config_theta_adv_order
        real (kind=RKIND), intent(in) :: config_coef_3rd_order

        real (kind=RKIND), dimension(nz1,nCells), intent(inout) :: pressure, t
        real (kind=RKIND), dimension(nz1,nCells), intent(in) :: qv
        real (kind=RKIND), dimension(nz1,nEdges), intent(in) :: u

        real (kind=RKIND), dimension(nz1,nCells), intent(out) :: rho, theta, rho_base, theta_base
        real (kind=RKIND), dimension(nCells), intent(out) :: precipw, surface_pressure
        real (kind=RKIND), dimension(nz,nCells), intent(out) :: w
        real (kind=RKIND), dimension(nz1,nEdges), intent(out) :: ru

        real (kind=RKIND), dimension(nz1,nCells) :: p, rho_zz
        real (kind=RKIND), dimension(nz1,nCells) :: ppb, pb, rtb, pp, rr
        real (kind=RKIND), dimension(nz,nCells) :: rw
        real (kind=RKIND) :: ztemp, p_check, flux
        integer :: iCell, iEdge, i, k, it, cell1, cell2

        !
        ! PI (exner), THETA (in-place em t), RHO_ZZ diagnostico inicial.
        !
        do iCell=1,nCells
            do k=1,nz1
                p(k,iCell) = (pressure(k,iCell) / p0) ** (rgas/cp)
                t(k,iCell) = t(k,iCell) * (p0/pressure(k,iCell)) ** (rgas/cp)
                rho_zz(k,iCell) = pressure(k,iCell) / rgas / (p(k,iCell)*t(k,iCell) &
                                   * (1.0_RKIND + (rvord-1.0_RKIND)*qv(k,iCell)))
                rho_zz(k,iCell) = rho_zz(k,iCell) / (1.0_RKIND + qv(k,iCell))
            end do
        end do

        !
        ! Agua precipitavel (usa o rho_zz diagnostico acima, ANTES do
        ! acoplamento com a metrica vertical).
        !
        do iCell=1,nCells
            precipw(iCell) = 0.0_RKIND
            do k=1,nz1
                precipw(iCell) = precipw(iCell) + rho_zz(k,iCell)*qv(k,iCell)*(zgrid(k+1,iCell)-zgrid(k,iCell))
            end do
        end do

        !
        ! Estado-base isotermico seco (t0b=250, p0=1e5).
        !
        do iCell=1,nCells
            do k=1,nz1
                ztemp = 0.5_RKIND*(zgrid(k+1,iCell)+zgrid(k,iCell))
                ppb(k,iCell) = p0*exp(-gravity*ztemp/(rgas*t0b))
                pb (k,iCell) = (ppb(k,iCell)/p0)**(rgas/cp)
                rho_base(k,iCell) = ppb(k,iCell)/(rgas*t0b)
                theta_base(k,iCell) = t0b/pb(k,iCell)
                rtb(k,iCell) = rho_base(k,iCell)*theta_base(k,iCell)
                p  (k,iCell) = pb(k,iCell)
                pp (k,iCell) = 0.0_RKIND
                rr (k,iCell) = 0.0_RKIND
            end do
        end do

        !
        ! Acoplamento com a metrica vertical (usa o rho_zz diagnostico).
        !
        do iCell=1,nCells
            do k=1,nz1
                rho_base(k,iCell)      = rho_base(k,iCell) / zz(k,iCell)
                rho_zz(k,iCell)  = rho_zz(k,iCell) / zz(k,iCell)
                pp(k,iCell) = pressure(k,iCell) - ppb(k,iCell)
                rr(k,iCell) = rho_zz(k,iCell) - rho_base(k,iCell)
            end do
        end do

        !
        ! Nivel 1: RECALCULADO com formula diferente da diagnostica acima
        ! (expoente cv/cp, fator umido 1.61*qv direto -- preservar como
        ! esta', nao reconciliar com a formula do bloco anterior).
        ! Niveis 2..nz1: solucao hidrostatica iterativa (ate 30 passadas,
        ! convergencia |Δpp|<0.0001), sequencial em k.
        !
        do iCell=1,nCells
            k = 1
            rho_zz(k,iCell) = ((pressure(k,iCell)/p0)**(cv/cp)) * (p0/rgas) &
                               / (t(k,iCell)*(1.0_RKIND + 1.61_RKIND*qv(k,iCell))) / zz(k,iCell)
            rr(k,iCell) = rho_zz(k,iCell) - rho_base(k,iCell)

            do k=2,nz1
                it = 0
                p_check = 2.0_RKIND * 0.0001_RKIND
                do while (it < 30 .and. p_check > 0.0001_RKIND)
                    p_check = pp(k,iCell)
                    pp(k,iCell) = pp(k-1,iCell) - (fzm(k)*rr(k,iCell) + fzp(k)*rr(k-1,iCell))*gravity*dzu(k) &
                                  - (fzm(k)*rho_zz(k,iCell)*qv(k,iCell) &
                                     + fzp(k)*rho_zz(k-1,iCell)*qv(k-1,iCell))*gravity*dzu(k)
                    pressure(k,iCell) = pp(k,iCell) + ppb(k,iCell)
                    p(k,iCell) = (pressure(k,iCell)/p0) ** (rgas/cp)
                    rho_zz(k,iCell) = pressure(k,iCell) / rgas &
                                       / (p(k,iCell)*t(k,iCell)*(1.0_RKIND + 1.61_RKIND*qv(k,iCell))) / zz(k,iCell)
                    rr(k,iCell) = rho_zz(k,iCell) - rho_base(k,iCell)

                    p_check = abs(p_check - pp(k,iCell))
                    it = it + 1
                end do
            end do
        end do

        !
        ! THETA_M (in-place em t) e desacoplamento de rr.
        !
        do iCell=1,nCells
            do k=1,nz1
                t(k,iCell)  = t(k,iCell) * (1.0_RKIND + 1.61_RKIND*qv(k,iCell))
                rr(k,iCell) = rr(k,iCell) * zz(k,iCell)
            end do
        end do

        !
        ! ru nas arestas. Aresta de borda da malha regional (so' uma
        ! celula real, cellsOnEdge==0 do outro lado) -- mesma convencao
        ! ja usada em compute_zb/zxu: substitui pela celula valida.
        !
        do iEdge=1,nEdges
            cell1 = cellsOnEdge(1,iEdge)
            cell2 = cellsOnEdge(2,iEdge)
            if (cell1 == 0) cell1 = cell2
            if (cell2 == 0) cell2 = cell1
            do k=1,nz1
                ru(k,iEdge) = u(k,iEdge) * 0.5_RKIND*(rho_zz(k,cell1) + rho_zz(k,cell2))
            end do
        end do

        !
        ! rw / w (velocidade vertical diagnostica). Fiel ao original: o
        ! loop e' k=2,nz1 (NAO ate' nz) -- fzm/fzp/dzu/ru/rho_zz sao
        ! indexados por camada (1..nz1=nVertLevels), e zb/zb3 (que no
        ! static.nc real tem dimensao nVertLevelsP1=nz) sao acessados com
        ! o MESMO k de camada, nunca k=nz. Efeito liquido, confirmado
        ! contra o init.nc real: w(1,:) e w(nz,:) ficam em zero (condicao
        ! de contorno no chao e no topo rigido), so' os interiores
        ! 2..nz1 sao computados -- exatamente como no original, mesmo
        ! rw/w sendo alocados com a dimensao maior (nz) do pool real.
        !
        rw(:,:) = 0.0_RKIND
        w(:,:)  = 0.0_RKIND

        do iCell=1,nCells
            do i=1,nEdgesOnCell(iCell)
                iEdge = edgesOnCell(i,iCell)
                cell1 = cellsOnEdge(1,iEdge)

                do k=2,nz1
                    flux = (fzm(k)*ru(k,iEdge) + fzp(k)*ru(k-1,iEdge))
                    if (iCell == cell1) then
                        rw(k,iCell) = rw(k,iCell) - (fzm(k)*zz(k,iCell) + fzp(k)*zz(k-1,iCell))*zb(k,1,iEdge)*flux
                    else
                        rw(k,iCell) = rw(k,iCell) + (fzm(k)*zz(k,iCell) + fzp(k)*zz(k-1,iCell))*zb(k,2,iEdge)*flux
                    end if

                    if (config_theta_adv_order == 3) then
                        if (iCell == cell1) then
                            rw(k,iCell) = rw(k,iCell) &
                                + sign(1.0_RKIND,ru(k,iEdge))*config_coef_3rd_order &
                                  * (fzm(k)*zz(k,iCell) + fzp(k)*zz(k-1,iCell))*zb3(k,1,iEdge)*flux
                        else
                            rw(k,iCell) = rw(k,iCell) &
                                - sign(1.0_RKIND,ru(k,iEdge))*config_coef_3rd_order &
                                  * (fzm(k)*zz(k,iCell) + fzp(k)*zz(k-1,iCell))*zb3(k,2,iEdge)*flux
                        end if
                    end if
                end do
            end do
        end do

        do iCell=1,nCells
            do k=2,nz1
                w(k,iCell) = rw(k,iCell) / (fzp(k)*rho_zz(k-1,iCell) + fzm(k)*rho_zz(k,iCell))
            end do
        end do

        !
        ! Pressao de superficie diagnostica (campo separado de "pressure",
        ! escrito como "surface_pressure" no init.nc).
        !
        do iCell=1,nCells
            surface_pressure(iCell) = 0.5_RKIND*gravity/rdzw(1) &
                                       * (1.25_RKIND*rho_zz(1,iCell)*(1.0_RKIND + qv(1,iCell)) &
                                          - 0.25_RKIND*rho_zz(2,iCell)*(1.0_RKIND + qv(2,iCell)))
            surface_pressure(iCell) = surface_pressure(iCell) + pp(1,iCell) + ppb(1,iCell)
        end do

        !
        ! rho/theta finais.
        !
        do iCell=1,nCells
            do k=1,nz1
                rho(k,iCell)   = rho_zz(k,iCell) * zz(k,iCell)
                theta(k,iCell) = t(k,iCell) / (1.0_RKIND + 1.61_RKIND*qv(k,iCell))
            end do
        end do

    end subroutine compute_hydrostatic_balance


    !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    ! compute_q2
    !
    ! Umidade especifica a 2m -- usa psfc JA AJUSTADO por topografia (saida
    ! da Fase 3), nao o PSFC bruto do first-guess.
    !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    subroutine compute_q2(nCells, t2m, psfc, rh2, q2)

        implicit none

        integer, intent(in) :: nCells
        real (kind=RKIND), dimension(nCells), intent(in) :: t2m, psfc, rh2
        real (kind=RKIND), dimension(nCells), intent(out) :: q2

        integer :: iCell
        real (kind=RKIND) :: es, rs

        do iCell=1,nCells
            es = 6.112_RKIND * exp((17.27_RKIND*(t2m(iCell) - 273.16_RKIND))/(t2m(iCell) - 35.86_RKIND))
            rs = 0.622_RKIND * es * 100.0_RKIND / (psfc(iCell) - es*100.0_RKIND)
            q2(iCell) = 0.01_RKIND * rs * rh2(iCell)
        end do

    end subroutine compute_q2


    !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    ! convert_relhum_wrt_ice
    !
    ! Corrige RH pra ser relativo ao gelo abaixo de 0C -- so' afeta o campo
    ! relhum de SAIDA, nao realimenta o qv ja calculado (mesma ordem do
    ! original: chamar DEPOIS de derivar qv de relhum, se for o caso).
    !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    subroutine convert_relhum_wrt_ice(nz1, nCells, t, relhum)

        implicit none

        integer, intent(in) :: nz1, nCells
        real (kind=RKIND), dimension(nz1,nCells), intent(in) :: t
        real (kind=RKIND), dimension(nz1,nCells), intent(inout) :: relhum

        integer :: iCell, k
        real (kind=RKIND) :: eis, ews, r1

        do iCell=1,nCells
            do k=1,nz1
                if (t(k,iCell) <= 273.15_RKIND) then
                    eis = 0.01_RKIND * exp(9.550426_RKIND - (5723.265_RKIND/t(k,iCell)) &
                          + (3.53068_RKIND*log(t(k,iCell))) - (0.00728332_RKIND*t(k,iCell)))
                    ews = 6.112_RKIND * exp(17.67_RKIND*(t(k,iCell)-273.15_RKIND) / ((t(k,iCell)-273.15_RKIND)+243.5_RKIND))

                    if (t(k,iCell) > 253.15_RKIND) then
                        r1 = ((273.15_RKIND - t(k,iCell)) / 20.0_RKIND)
                        r1 = (r1*eis) + ((1.0_RKIND-r1)*ews)
                    else
                        r1 = eis
                    end if
                    r1  = max(r1, 1.0e-12_RKIND)
                    ews = max(ews, 0.0_RKIND)
                    relhum(k,iCell) = ews / r1 * relhum(k,iCell)
                    relhum(k,iCell) = min(relhum(k,iCell), 100.0_RKIND)
                    relhum(k,iCell) = max(relhum(k,iCell), 0.0_RKIND)
                end if
            end do
        end do

    end subroutine convert_relhum_wrt_ice

end module hydrostatic
