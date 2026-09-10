! Fase 6 (campos de superficie/solo do init.nc) do plano de interpolacao
! nativa Voronoi. Extraido literalmente de
! MPAS-Model/src/core_atmosphere/physics/mpas_atmphys_initialize_real.F
! (correcao de path 2026-09-10: NAO fica em core_init_atmosphere, fica em
! core_atmosphere/physics -- comentario original tinha o path errado) e
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
    public :: adjust_soil_lapse_rate
    public :: resample_soil_profile
    public :: reclassify_seaice

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


    !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    ! adjust_soil_lapse_rate
    !
    ! Item 2 do plano de fidelidade (doc_voronoi/PLANO_FIDELIDADE.md).
    ! Porta literal do bloco relevante de
    ! mpas_atmphys_initialize_real.F :: adjust_input_soiltemps
    ! (mpas-bundle-3.0.2, ~linha 217): corrige o perfil de temperatura de
    ! solo do first-guess (st_fg, todos os niveis) pela diferenca de
    ! elevacao entre o terreno real da malha-alvo (ter, ja' misturado na
    ! fronteira se config_blend_bdy_terrain -- item 1) e o terreno do
    ! first-guess (soilz_fg == SOILHGT). MESMA formula/constante (lapse
    ! rate padrao, 6.5 K/km) ja' usada em gen_init_native.F90 pra
    ! skintemp/tmn -- so' que ali nunca era aplicada ao perfil de solo
    ! inteiro (fg_tslb era copiado sem correcao). soilz_fg NAO e' o mesmo
    ! automaticamente igual a' soilhgt usado no skintemp: sao a mesma
    ! variavel fisica (SOILHGT), mantida separada aqui so' por clareza de
    ! nome/uso.
    !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    subroutine adjust_soil_lapse_rate(nCells, nFGSoilLevels, landmask, ter, soilz_fg, st_fg)

        implicit none

        integer, intent(in) :: nCells, nFGSoilLevels
        integer, dimension(nCells), intent(in) :: landmask
        real (kind=RKIND), dimension(nCells), intent(in) :: ter, soilz_fg
        real (kind=RKIND), dimension(nFGSoilLevels,nCells), intent(inout) :: st_fg

        integer :: iCell, ifgSoil

        do iCell = 1, nCells
            if (landmask(iCell) == 1) then
                do ifgSoil = 1, nFGSoilLevels
                    st_fg(ifgSoil,iCell) = st_fg(ifgSoil,iCell) - 0.0065_RKIND * (ter(iCell) - soilz_fg(iCell))
                end do
            end if
        end do

    end subroutine adjust_soil_lapse_rate


    !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    ! resample_soil_profile
    !
    ! Item 2 do plano de fidelidade. Porta literal de
    ! mpas_atmphys_initialize_real.F :: init_soil_layers_depth +
    ! init_soil_layers_properties (mpas-bundle-3.0.2, ~linhas 273-513):
    ! reamostra o perfil de temperatura/umidade de solo do first-guess
    ! (profundidades dzs_fg_cm, EM CENTIMETROS -- mesma convencao do
    ! original) para as profundidades-padrao Noah do alvo (zs, em METROS,
    ! ponto medio de cada camada), via interpolacao linear por
    ! profundidade, ancorada em skintemp (z=0) e tmn (z=3m) nas
    ! extremidades. st_fg deve chegar aqui JA' com o lapse-rate aplicado
    ! (adjust_soil_lapse_rate, acima).
    !
    ! Preserva DELIBERADAMENTE duas excentricidades do original (ver
    ! mesmo trecho no MPAS-Model, nao sao erros desta porta):
    !  - sm_input(1) (ancora em z=0, agua) usa sm_fg(2), NAO sm_fg(1);
    !  - sm_input(nFGSoilLevels+2) (ancora em z=3m) usa
    !    sm_input(nFGSoilLevels), NAO sm_input(nFGSoilLevels+1) (a ultima
    !    camada real do first-guess).
    ! Nenhuma das duas afeta o caso validado (MPAS-A -> MPAS-A, mesmas 4
    ! profundidades-padrao na origem e no destino): quando dzs_fg_cm ==
    ! dzs (destino), zs coincide exatamente com os pontos internos de
    ! zhave, e a interpolacao degenera em identidade (tslb=st_fg,
    ! smois=sm_fg, campo a campo) SEM nunca usar as ancoras de borda --
    ! validado numericamente comparando contra a copia direta anterior.
    !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    subroutine resample_soil_profile(nCells, nFGSoilLevels, nSoilLevels, dzs_fg_cm, &
                                      st_fg, sm_fg, skintemp, tmn, zs, tslb, smois)

        implicit none

        integer, intent(in) :: nCells, nFGSoilLevels, nSoilLevels
        real (kind=RKIND), dimension(nFGSoilLevels), intent(in) :: dzs_fg_cm
        real (kind=RKIND), dimension(nFGSoilLevels,nCells), intent(in) :: st_fg, sm_fg
        real (kind=RKIND), dimension(nCells), intent(in) :: skintemp, tmn
        real (kind=RKIND), dimension(nSoilLevels,nCells), intent(in) :: zs
        real (kind=RKIND), dimension(nSoilLevels,nCells), intent(out) :: tslb, smois

        real (kind=RKIND), dimension(nFGSoilLevels+2) :: zhave, st_input, sm_input
        integer :: iCell, iSoil, ifgSoil
        real (kind=RKIND) :: zs_fg_accum

        do iCell = 1, nCells

            zhave(1) = 0.0_RKIND
            st_input(1) = skintemp(iCell)
            sm_input(1) = sm_fg(2,iCell)   ! excentricidade do original, ver nota acima

            zs_fg_accum = 0.0_RKIND
            do ifgSoil = 1, nFGSoilLevels
                if (ifgSoil == 1) then
                    zs_fg_accum = 0.5_RKIND * dzs_fg_cm(1)
                else
                    zs_fg_accum = zs_fg_accum + 0.5_RKIND*dzs_fg_cm(ifgSoil-1) + 0.5_RKIND*dzs_fg_cm(ifgSoil)
                end if
                zhave(ifgSoil+1) = zs_fg_accum / 100.0_RKIND
                st_input(ifgSoil+1) = st_fg(ifgSoil,iCell)
                sm_input(ifgSoil+1) = sm_fg(ifgSoil,iCell)
            end do

            zhave(nFGSoilLevels+2) = 300.0_RKIND / 100.0_RKIND
            st_input(nFGSoilLevels+2) = tmn(iCell)
            sm_input(nFGSoilLevels+2) = sm_input(nFGSoilLevels)   ! excentricidade do original, ver nota acima

            do iSoil = 1, nSoilLevels
                do ifgSoil = 1, nFGSoilLevels+1
                    if (zs(iSoil,iCell) >= zhave(ifgSoil) .and. zs(iSoil,iCell) <= zhave(ifgSoil+1)) then
                        tslb(iSoil,iCell) = ( st_input(ifgSoil)   * (zhave(ifgSoil+1)-zs(iSoil,iCell)) &
                                             + st_input(ifgSoil+1) * (zs(iSoil,iCell)-zhave(ifgSoil)) ) &
                                            / (zhave(ifgSoil+1)-zhave(ifgSoil))
                        smois(iSoil,iCell) = ( sm_input(ifgSoil)   * (zhave(ifgSoil+1)-zs(iSoil,iCell)) &
                                              + sm_input(ifgSoil+1) * (zs(iSoil,iCell)-zhave(ifgSoil)) ) &
                                             / (zhave(ifgSoil+1)-zhave(ifgSoil))
                        exit
                    end if
                end do
            end do

        end do

    end subroutine resample_soil_profile


    !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    ! reclassify_seaice
    !
    ! Item 3 do plano de fidelidade (doc_voronoi/PLANO_FIDELIDADE.md).
    ! Extraido literalmente de duas rotinas em
    ! mpas_atmphys_initialize_real.F (mpas-bundle-3.0.2):
    ! physics_init_sst (~linha 516) -- forca temperatura de pele = TSM
    ! sobre oceano aberto e faz uma limpeza defensiva de xice; e
    ! physics_init_seaice (~linha 586) -- reclassifica celulas de agua
    ! muito fria (fracao de gelo acima do limiar OU temperatura de pele
    ! abaixo de config_tsk_seaice_threshold) como celulas de gelo/terra,
    ! ajustando em cascata uso do solo, textura de solo, albedo maximo de
    ! neve, vegetacao, mascara terra/agua dinamica (xland) e o perfil de
    ! solo (tslb/smois/sh2o).
    !
    ! ACHADO 2026-09-10: no driver real (physics_initialize_real, mesmo
    ! arquivo, ~linha 68), physics_init_sst so' e' chamada dentro de
    ! "if (config_input_sst) then" -- ou seja, so' quando a TSM/gelo vem
    ! de um arquivo auxiliar SEPARADO (nao o caso deste projeto: o
    ! namelist real usa config_input_sst=.false., TSM vem do proprio
    ! first-guess via extract_fields). physics_init_seaice, por outro
    ! lado, e' chamada incondicionalmente. Por isso o bloco tsk=SST +
    ! limpeza defensiva (fisicamente parte de physics_init_sst) e'
    ! condicionado aqui a config_input_sst -- inclui-lo incondicionalmente
    ! teria forcado skintemp=SST em toda celula de oceano do caso
    ! validado, um desvio real do comportamento de referencia (achado ao
    ! validar contra o init.nc real, ver PLANO_FIDELIDADE.md item 3).
    !
    ! Nao mexe em landmask (mascara ESTATICA, inalterada no original --
    ! so' xland, a mascara DINAMICA usada pela fisica, e' que muda). Os
    ! valores fixos (isltyp=16, snoalb=0.75, tmn=271.4K, smois=1.0,
    ! sh2o=0.0) sao constantes do algoritmo de referencia, preservadas
    ! exatamente -- nao calibradas por este trabalho.
    !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    subroutine reclassify_seaice(nCells, nSoilLevels, landmask, isice_lu, &
                                  config_input_sst, xice_threshold, tsk_seaice_threshold, sst, &
                                  xice, skintemp, tmn, ivgtyp, isltyp, snoalb, &
                                  vegfra, xland, tslb, smois, sh2o, seaice)

        implicit none

        integer, intent(in) :: nCells, nSoilLevels
        integer, dimension(nCells), intent(in) :: landmask
        integer, intent(in) :: isice_lu
        logical, intent(in) :: config_input_sst
        real (kind=RKIND), intent(in) :: xice_threshold, tsk_seaice_threshold
        real (kind=RKIND), dimension(nCells), intent(in) :: sst

        real (kind=RKIND), dimension(nCells), intent(inout) :: xice, skintemp, tmn
        integer, dimension(nCells), intent(inout) :: ivgtyp, isltyp
        real (kind=RKIND), dimension(nCells), intent(inout) :: snoalb, vegfra, xland
        real (kind=RKIND), dimension(nSoilLevels,nCells), intent(inout) :: tslb, smois, sh2o
        real (kind=RKIND), dimension(nCells), intent(out) :: seaice

        real (kind=RKIND), parameter :: total_depth = 3.0_RKIND  ! 3m, mesma convencao do original
        integer :: iCell, iSoil
        real (kind=RKIND) :: mid_point_depth

        ! ---- physics_init_sst (so' roda se config_input_sst=.true.) ----
        if (config_input_sst) then
            ! tsk = TSM sobre oceano aberto/pouco gelo:
            do iCell = 1, nCells
                if (landmask(iCell) == 0 .and. xice(iCell) < xice_threshold) then
                    skintemp(iCell) = sst(iCell)
                end if
            end do

            ! limpeza defensiva de xice espurio (celula de terra com
            ! xice>0, ou valor sentinela/lixo >200):
            do iCell = 1, nCells
                if ((landmask(iCell) == 1 .and. xice(iCell) > 0.0_RKIND) .or. &
                     xice(iCell) > 200.0_RKIND) then
                    xice(iCell) = 0.0_RKIND
                end if
            end do
        end if

        ! ---- physics_init_seaice: reclassificacao em cascata (sempre) ----
        do iCell = 1, nCells
            if (xice(iCell) >= xice_threshold .or. &
               (landmask(iCell) == 0 .and. skintemp(iCell) < tsk_seaice_threshold)) then

                if (landmask(iCell) == 0) tmn(iCell) = 271.4_RKIND
                ivgtyp(iCell) = isice_lu
                isltyp(iCell) = 16
                snoalb(iCell) = 0.75_RKIND
                vegfra(iCell) = 0.0_RKIND
                xland(iCell)  = 1.0_RKIND

                do iSoil = 1, nSoilLevels
                    mid_point_depth = total_depth/real(nSoilLevels,RKIND)/2.0_RKIND &
                                     + real(iSoil-1,RKIND)*(total_depth/real(nSoilLevels,RKIND))
                    tslb(iSoil,iCell) = ( (total_depth-mid_point_depth) * skintemp(iCell) &
                                         + mid_point_depth * tmn(iCell) ) / total_depth
                    smois(iSoil,iCell) = 1.0_RKIND
                    sh2o(iSoil,iCell)  = 0.0_RKIND
                end do

            else if (xice(iCell) < xice_threshold) then
                xice(iCell) = 0.0_RKIND
            end if
        end do

        ! ---- physics_init_seaice: atualizacao final da flag seaice ----
        do iCell = 1, nCells
            seaice(iCell) = 0.0_RKIND
            if (xice(iCell) > 0.0_RKIND) seaice(iCell) = 1.0_RKIND
        end do

    end subroutine reclassify_seaice

end module surface_fields
