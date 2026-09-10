! Fase 2 do plano de interpolacao nativa Voronoi (ver
! /home/dvar/.claude/plans/cheerful-knitting-platypus.md e
! doc_voronoi/prototipo_scatter/). Adaptado (extracao literal das formulas,
! removendo apenas o framework de pools/log/MPI do MPAS -- mesma convencao
! ja usada em interp_vertical.F90) do bloco `config_tc_vertical_grid` de
! `init_atm_case_gfs`, MPAS-Dev/MPAS-Model, src/core_init_atmosphere/
! mpas_init_atm_cases.F (linhas ~3015-3447 na revisao consultada em
! 2026-09-08). Conferido que a rodada real de producao (namelist.init_atmosphere
! em /mnt/dados2/FILE_BASE e nos diretorios init_run/lbc_run de
! ungrib_to_mpas/recortes/SouthAmerica) usa config_tc_vertical_grid=true,
! nao o branch generico de MPAS 2.0 -- por isso e' esse o branch extraido
! aqui, nao o outro.
!
! Diferencas deliberadas do original:
!  - Sem mpas_dmpar_exch_halo_field/mpas_dmpar_min_real/mpas_dmpar_max_real:
!    este codigo roda serial sobre a malha inteira (nao distribuida em
!    blocos MPI), entao nao ha halo pra trocar.
!  - "Celula-lixo" (cellsOnCell(j,iCell) == nCells+1, convencao interna do
!    framework MPAS pra vizinho ausente dentro de um bloco distribuido) foi
!    traduzida para a convencao usada no arquivo .static.nc bruto: vizinho
!    ausente = cellsOnCell(j,iCell) == 0 (borda de malha regional/limited-area).
!    Mesmo efeito fisico (condicao de contorno Neumann/gradiente-zero): o
!    valor do "vizinho" ausente e' igualado ao da propria celula.
!  - config_specified_zeta_levels nao implementado (vazio nos namelists
!    reais -- sempre cai no branch config_tc_vertical_grid).
!
! NOTA (2026-09-09, corrige comentario antigo): config_hybrid_coordinate
! ESTA implementado (ver argumento homonimo de compute_vertical_grid) --
! nao aparece explicitamente nos namelists reais porque o default do
! Registry.xml ja e' "true" (achado da investigacao da divergencia de
! ~2km na grade vertical, ver doc_voronoi/relatorio_tecnico ou memoria
! project-vertical-grid-divergence). config_smooth_surfaces (logical,
! liga/desliga a suavizacao iterativa de hx por nivel) tambem NAO esta
! conectado ainda -- a suavizacao roda incondicionalmente quando
! config_nsm>0, o que so' e' equivalente a config_smooth_surfaces=true
! (o default, e o valor usado no unico caso validado) -- ver
! doc_voronoi/PLANO_FIDELIDADE.md, item 6.
!
! IMPORTANTE (achado em 2026-09-08, validando contra SouthAmerica.init.nc
! real): o binario real do init_atmosphere_model usado em produção foi
! compilado com "Default real precision: single" (confirmado no log
! log.init_atmosphere.0000.out) -- ou seja, RKIND real la' e' real*4, nao
! real*8 como o mpas_kind_types.F90 padrao (e como este projeto ja usava
! em interp_vertical.F90/extract_fields.F90). Isso importa MUITO aqui: a
! suavizacao iterativa de hx (abaixo) tem um criterio de aceitacao por
! limiar (dzmina > dzmin*Δzw) que e' sensivel a diferencas minusculas de
! arredondamento, compostas ao longo de ate ~85 passadas x ~53 niveis --
! calculando em double precision a rotina diverge da saida real em ate
! ~2km em hx (validado numericamente). Por isso as variaveis diretamente
! envolvidas na suavizacao (terreno + hx + acumuladores) usam SPKIND
! (single) aqui, propositalmente, para casar com o binario real -- nao e'
! um descuido. O resto (zw/ah/zgrid/zz/etc.) continua em RKIND (double),
! ja que essa parte bateu quase exata em double (formula fechada, nao
! iterativa).

module vertical_grid

    use mpas_kind_types, only : RKIND
    use mpas_constants, only : gravity, rgas, cp, pii

    implicit none

    integer, parameter :: SPKIND = selected_real_kind(6)

    public :: compute_vertical_grid, compute_zb, blend_bdy_terrain_native

    contains

    !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    ! compute_vertical_grid
    !
    ! Gera a grade vertical nativa (zgrid/zz/zxu/rdzw/dzu/rdzu/fzm/fzp/
    ! cf1/cf2/cf3/dss) para uma malha MPAS de destino, a partir do terreno
    ! (ter) e da conectividade da malha -- nao depende de nenhum dado
    ! meteorologico.
    !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    subroutine compute_vertical_grid(nCells, nEdges, maxEdges, nVertLevels, &
                                      nEdgesOnCell, cellsOnCell, edgesOnCell, cellsOnEdge, &
                                      dvEdge, dcEdge, ter_raw, &
                                      config_ztop, config_nsmterrain, config_nsm, config_dzmin, &
                                      config_hybrid_coordinate, config_hybrid_top_z, &
                                      config_smooth_surfaces, config_tc_vertical_grid, &
                                      config_interface_projection, &
                                      zgrid, zz, zxu, rdzw, dzu, rdzu, fzm, fzp, cf1, cf2, cf3, dss, &
                                      ter_smoothed)

        implicit none

        integer, intent(in) :: nCells, nEdges, maxEdges, nVertLevels
        integer, dimension(nCells), intent(in) :: nEdgesOnCell
        integer, dimension(maxEdges,nCells), intent(in) :: cellsOnCell, edgesOnCell
        integer, dimension(2,nEdges), intent(in) :: cellsOnEdge
        real (kind=RKIND), dimension(nEdges), intent(in) :: dvEdge, dcEdge
        real (kind=RKIND), dimension(nCells), intent(in) :: ter_raw
        real (kind=RKIND), intent(in) :: config_ztop, config_dzmin, config_hybrid_top_z
        integer, intent(in) :: config_nsmterrain, config_nsm
        logical, intent(in) :: config_hybrid_coordinate
        ! Item 6 do plano de fidelidade (doc_voronoi/PLANO_FIDELIDADE.md):
        ! liga/desliga a suavizacao iterativa de hx por nivel abaixo.
        ! Achado 2026-09-10 confirmando no codigo real
        ! (mpas_init_atm_cases.F, ~linha 3217-3300): quando .false., o
        ! ramo "else" NAO substitui por outra logica -- so' faz logging,
        ! deixando hx(k,:) igual ao terreno ja suavizado pela 4a ordem em
        ! TODOS os niveis (valor ja atribuido antes desta subrotina
        ! entrar no laco por nivel, ver bloco de suavizacao de terreno
        ! acima). Por isso o ramo .false. aqui nao precisa reatribuir
        ! nada -- so' pular o laco de suavizacao por nivel.
        logical, intent(in) :: config_smooth_surfaces
        ! Nova formula alternativa (achado 2026-09-10, a pedido do
        ! usuario -- refletir as duas ramificacoes de toda flag config_*,
        ! nao so' a usada no caso validado). Confirmado no codigo real
        ! (mpas_init_atm_cases.F, ~linha 3040-3130) que a escolha de
        ! z_w(k) e' na verdade um if/else-if/else de TRES vias, nao um
        ! true/false simples: (1) config_specified_zeta_levels (arquivo
        ! externo de niveis, string nao-vazia -- fora de escopo, sempre
        ! vazio nos namelists reais deste projeto, ja documentado);
        ! (2) config_tc_vertical_grid=.true. (formula "2014 TC
        ! experiments", ja implementada abaixo); (3) senao, a formula
        ! "MPAS 2.0 e anterior" -- unico ramo que faltava, adicionado
        ! aqui.
        logical, intent(in) :: config_tc_vertical_grid
        character (len=*), intent(in) :: config_interface_projection

        real (kind=RKIND), dimension(nVertLevels+1,nCells), intent(out) :: zgrid
        real (kind=RKIND), dimension(nVertLevels,nCells), intent(out) :: zz, dss
        real (kind=RKIND), dimension(nVertLevels,nEdges), intent(out) :: zxu
        real (kind=RKIND), dimension(nVertLevels), intent(out) :: rdzw, dzu, rdzu, fzm, fzp
        real (kind=RKIND), intent(out) :: cf1, cf2, cf3
        ! Terreno JA' suavizado (4a ordem, config_nsmterrain passadas) --
        ! achado 2026-09-09 investigando o item 2 do plano de fidelidade:
        ! ter_raw (entrada) e' intent(in) e a suavizacao rodava so' numa
        ! copia local (ter, SPKIND); o chamador nunca recebia o terreno
        ! suavizado de volta, e usava o cru (so' com blend de fronteira,
        ! sem suavizacao) pra corrigir skintemp/tslb por lapso termico --
        ! diferente do original, onde 'ter' e' a MESMA variavel do pool,
        ! mutada in-place pela suavizacao, entao todo uso posterior (lapso
        ! termico incluso) ja' ve' o terreno suavizado. Corrigido expondo
        ! esse valor aqui.
        real (kind=RKIND), dimension(nCells), intent(out) :: ter_smoothed

        integer :: nz, nz1, i, j, k, iCell, iEdge, kz
        real (kind=RKIND) :: zt, dz, als, alt, zetal, zl, zh, dzmin
        real (kind=RKIND) :: cof1, cof2
        real (kind=RKIND), dimension(nVertLevels+1) :: zw, ah
        real (kind=RKIND), dimension(nVertLevels) :: zu, dzw
        integer :: nb, cell1, cell2

        ! Precisao simples deliberada aqui -- ver nota no topo do modulo.
        real (kind=SPKIND) :: sm, dcsum, dzmina, dzminf, nbval
        real (kind=SPKIND), dimension(nCells) :: ter, hs, hs1, sm0, hxk
        real (kind=SPKIND), dimension(:,:), allocatable :: hx
        real (kind=SPKIND), dimension(nEdges) :: dvEdge_sp, dcEdge_sp
        real (kind=SPKIND) :: zw_sp, zh_sp, ah_sp, ah_km1_sp, dzmin_sp, zwkm1_sp, zwk_zwkm1_sp
        logical :: debug_smoothing_log

        nz1 = nVertLevels
        nz  = nVertLevels + 1

        dvEdge_sp = real(dvEdge, SPKIND)
        dcEdge_sp = real(dcEdge, SPKIND)

        !
        ! Suavizador de 4a ordem no terreno (config_nsmterrain passadas,
        ! tipicamente 1) -- MPAS-Model mpas_init_atm_cases.F, bloco logo
        ! apos "if (config_vertical_grid) then".
        !
        ter = real(ter_raw, SPKIND)
        do i=1,config_nsmterrain
            call shapiro_pass(nCells, maxEdges, nEdgesOnCell, cellsOnCell, edgesOnCell, dvEdge_sp, dcEdge_sp, &
                               0.216_SPKIND, ter, hs)
            ter = hs
            call shapiro_pass(nCells, maxEdges, nEdgesOnCell, cellsOnCell, edgesOnCell, dvEdge_sp, dcEdge_sp, &
                               -0.216_SPKIND, ter, hs)
            ter = hs
        end do

        ter_smoothed = real(ter, RKIND)

        allocate(hx(nz,nCells))
        do iCell=1,nCells
            hx(:,iCell) = ter(iCell)
        end do

        !
        ! zw(k): tres vias possiveis no original (ver nota no argumento
        ! config_tc_vertical_grid acima); config_specified_zeta_levels
        ! (arquivo externo) fora de escopo, entao so' duas ramificacoes
        ! aqui.
        !
        zt = config_ztop
        dz = zt/real(nz1,RKIND)

        if (config_tc_vertical_grid) then
            ! "Setting up vertical levels as in 2014 TC experiments" --
            ! constantes calibradas para nVertLevels=55 (unico caso usado
            ! em producao neste projeto).
            if (nVertLevels >= 55) then
                als   = 0.075_RKIND
                alt   = 1.70_RKIND
                zetal = 0.75_RKIND
            else
                als   = 0.075_RKIND
                alt   = 1.23_RKIND
                zetal = 0.31_RKIND
            end if

            do k=1,nz
                zl = 1.0_RKIND - alt*(1.0_RKIND-zetal)
                if ((real(k-1,RKIND)/real(nz1,RKIND)) < zetal) then
                    zw(k) = ( als*real(k-1,RKIND)/real(nz1,RKIND)                                   &
                            + (3.0_RKIND*(1.0_RKIND-alt)+2.0_RKIND*(alt-als)*zetal)                 &
                                  *(real(k-1,RKIND)*dz/(zt*zetal))**2                               &
                            - (2.0_RKIND*(1.0_RKIND-alt) + (alt-als)*zetal)                         &
                                  *(real(k-1,RKIND)*dz/(zt*zetal))**3 ) * zt
                else
                    zw(k) = (zl+alt*(real(k-1,RKIND)/real(nz1,RKIND)-zetal))*zt
                end if
            end do
        else
            ! "Setting up vertical levels as in MPAS 2.0 and earlier" --
            ! extracao literal, mpas_init_atm_cases.F ~linha 3121-3129.
            ! Formula bem mais simples: perfil de potencia pura, sem
            ! calibracao por nVertLevels.
            do k=1,nz
                zw(k) = (real(k-1,RKIND)/real(nz1,RKIND))**1.5_RKIND * zt
            end do
        end if

        ! ah(k): achado 2026-09-09 (memoria project-vertical-grid-divergence)
        ! -- config_hybrid_coordinate NAO aparece nos namelists reais, mas o
        ! default do Registry.xml do MPAS-Model e' default_value="true" (com
        ! config_hybrid_top_z default_value="30000.0"), entao a rodada real
        ! usa a coordenada hibrida (formula cos**6), NAO ah(k)=1-zw(k)/zt
        ! como esta traducao assumia ate' agora (confirmado batendo os
        ! valores de ah(k) do log real, "interface k, height, ah value",
        ! contra as duas formulas -- so' a hibrida bate).
        kz = nz
        if (config_hybrid_coordinate) then
            zh = config_hybrid_top_z
            do k=1,nz
                if (zw(k) < zh) then
                    ah(k) = cos(0.5_RKIND*pii*zw(k)/zh)**6
                else
                    ah(k) = 0.0_RKIND
                    kz = min(kz,k)
                end if
            end do
        else
            zh = zt
            do k=1,nz
                ah(k) = 1.0_RKIND - zw(k)/zt
            end do
        end if

        ! dzu/rdzu/fzm/fzp(1) nao sao definidos pelo codigo original (so'
        ! preenche k=2,nz1) -- conferido no init.nc real que ficam em 0,
        ! nao lixo de memoria (pools do MPAS sao zerados na alocacao).
        dzu = 0.0_RKIND
        rdzu = 0.0_RKIND
        fzm = 0.0_RKIND
        fzp = 0.0_RKIND

        do k=1,nz1
            dzw(k)  = zw(k+1)-zw(k)
            rdzw(k) = 1.0_RKIND/dzw(k)
            zu(k)   = 0.5_RKIND*(zw(k)+zw(k+1))
        end do
        do k=2,nz1
            dzu(k)  = 0.5_RKIND*(dzw(k)+dzw(k-1))
            rdzu(k) = 1.0_RKIND/dzu(k)
        end do

        if (trim(config_interface_projection) == 'linear_interpolation') then
            do k=2,nz1
                fzp(k) = 0.5_RKIND*dzw(k)  /dzu(k)
                fzm(k) = 0.5_RKIND*dzw(k-1)/dzu(k)
            end do
        else if (trim(config_interface_projection) == 'layer_integral') then
            do k=2,nz1
                fzm(k) = 0.5_RKIND*dzw(k)  /dzu(k)
                fzp(k) = 0.5_RKIND*dzw(k-1)/dzu(k)
            end do
        end if

        cof1 = (2.0_RKIND*dzu(2)+dzu(3))/(dzu(2)+dzu(3))*dzw(1)/dzu(2)
        cof2 =              dzu(2)      /(dzu(2)+dzu(3))*dzw(1)/dzu(3)
        cf1  = fzp(2) + cof1
        cf2  = fzm(2) - cof1 - cof2
        cf3  = cof2

        !
        ! Suavizacao iterativa de hx por nivel (config_nsm + k passadas),
        ! ponderada pela resolucao local da malha (sm0).
        !
        dzmin_sp = real(config_dzmin, SPKIND)
        zh_sp = real(zh, SPKIND)
        do iCell=1,nCells
            dcsum = 0.0_SPKIND
            do j=1,nEdgesOnCell(iCell)
                dcsum = dcsum + dcEdge_sp(edgesOnCell(j,iCell))
            end do
            dcsum = dcsum / real(nEdgesOnCell(iCell),SPKIND)
            sm0(iCell) = max(0.01_SPKIND, 0.125_SPKIND * min(1.0_SPKIND, 3000.0_SPKIND/dcsum))
        end do

        block
            character (len=8) :: env_val
            integer :: env_stat
            call get_environment_variable('LOG_SMOOTHING', env_val, status=env_stat)
            debug_smoothing_log = (env_stat == 0)
        end block
        if (debug_smoothing_log) then
            write(0,'(A)') ' level, smoothing steps, smoothing factor, smallest fractional dz'
        end if

        if (config_smooth_surfaces) then
        do k=2,kz-1
            hx(k,:) = hx(k-1,:)
            zw_sp = real(zw(k), SPKIND)
            ah_sp = real(ah(k), SPKIND)
            ah_km1_sp = real(ah(k-1), SPKIND)
            ! zw(k-1) convertido diretamente para SPKIND (nao via
            ! zw(k)-diff) -- casa com o binario real de producao, onde
            ! RKIND JA e' single em todo o array zw, entao a subtracao
            ! nativa la' e' sempre single-menos-single, nunca
            ! arredonda-diferenca-de-double. Ver achado 2026-09-09 na
            ! memoria project-vertical-grid-divergence: essa era a unica
            ! divergencia de caminho de arredondamento encontrada entre
            ! esta traducao e mpas_init_atm_cases.F (linhas 3283-3333).
            zwkm1_sp = real(zw(k-1), SPKIND)
            zwk_zwkm1_sp = zw_sp - zwkm1_sp
            dzminf = zwk_zwkm1_sp

            do i=1,config_nsm + k
                ! Copia contigua de hx(k,:) (constante ao longo desta
                ! passada, so' e' atualizada no final dela abaixo) --
                ! evitar indexar hx(k,neighbor) direto aqui dentro do loop
                ! de vizinhos: hx(k,:) e' uma fatia NAO-contigua (primeiro
                ! indice fixo, segundo variando) e passa-la repetidamente
                ! (ou reindexa-la) ~3e8 vezes no total deixava isso
                ! ordens de magnitude mais lento (minutos em vez de
                ! segundos, medido).
                hxk = hx(k,:)

                do iCell=1,nCells
                    sm = sm0(iCell) * min((3.0_SPKIND*zw_sp/zh_sp)**2.0_SPKIND, 1.0_SPKIND)

                    hs1(iCell) = 0.0_SPKIND
                    do j=1,nEdgesOnCell(iCell)
                        nb = cellsOnCell(j,iCell)
                        if (nb == 0) then
                            nbval = hxk(iCell)
                        else
                            nbval = hxk(nb)
                        end if
                        hs1(iCell) = hs1(iCell) + dvEdge_sp(edgesOnCell(j,iCell)) / dcEdge_sp(edgesOnCell(j,iCell)) &
                                     * (nbval - hxk(iCell))
                    end do
                    hs(iCell) = hxk(iCell) + sm*hs1(iCell)
                end do

                do iCell=1,nCells
                    dzmina = (zw_sp + ah_sp*hs(iCell)) - (zwkm1_sp + ah_km1_sp*hx(k-1,iCell))
                    if (dzmina > dzmin_sp*zwk_zwkm1_sp) then
                        hx(k,iCell) = hs(iCell)
                        if (dzmina < dzminf) dzminf = dzmina
                    end if
                end do
            end do

            if (debug_smoothing_log) then
                write(0,'(I0,1X,I0,1X,ES14.7,1X,ES14.7)') k, config_nsm+k+1, sm, dzminf/zwk_zwkm1_sp
            end if
        end do
        do k=kz,nz
            hx(k,:) = 0.0_SPKIND
        end do
        end if
        ! config_smooth_surfaces=.false.: nada a fazer aqui -- hx(k,:)
        ! ja' vale ter(iCell) (terreno com suavizacao de 4a ordem) em
        ! TODOS os niveis desde o bloco anterior, e o codigo de
        ! referencia nao reatribui nada no ramo .false. (so' faz
        ! logging). zw(k)>=zh (onde ah(k)=0 e hx deixaria de importar)
        ! nao precisa do zero-out explicito aqui pelo mesmo motivo: com
        ! ah(k)=0, zgrid(k,i)=zw(k) independente do valor de hx(k,i).

        !
        ! Altura final das interfaces (zgrid), metrica vertical (zz), e
        ! zxu (dz/dx nas arestas).
        !
        do iCell=1,nCells
            do k=1,nz
                zgrid(k,iCell) = zw(k) + ah(k)*hx(k,iCell)
            end do
            do k=1,nz1
                zz(k,iCell) = (zw(k+1)-zw(k))/(zgrid(k+1,iCell)-zgrid(k,iCell))
            end do
        end do

        do iEdge=1,nEdges
            cell1 = cellsOnEdge(1,iEdge)
            cell2 = cellsOnEdge(2,iEdge)
            if (cell1 == 0) cell1 = cell2
            if (cell2 == 0) cell2 = cell1
            do k=1,nz1
                zxu(k,iEdge) = 0.5_RKIND * ( zgrid(k,  cell2) - zgrid(k,  cell1) &
                                            + zgrid(k+1,cell2) - zgrid(k+1,cell1) ) &
                               / dcEdge(iEdge)
            end do
        end do

        ! dss (coeficiente de amortecimento w perto do topo): xnutr=0. no
        ! caso de dado real (nao e' exposto como namelist pro caso GFS),
        ! entao dss e' sempre zero -- mesmo valor que o init_atmosphere_model
        ! real escreve pra esse caso.
        dss = 0.0_RKIND

        deallocate(hx)

    end subroutine compute_vertical_grid


    !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    ! blend_bdy_terrain_native
    !
    ! Mistura o terreno da malha-alvo (ter, de static.nc) com o terreno do
    ! first-guess no anel de fronteira (bdyMaskCell > 0), ANTES de gerar a
    ! grade vertical -- item 1 do plano de fidelidade
    ! (doc_voronoi/PLANO_FIDELIDADE.md). Extraido/adaptado de
    ! mpas_init_atm_cases.F :: blend_bdy_terrain (MPAS-Dev/MPAS-Model,
    ! mpas-bundle-3.0.2, ~linha 6791), chamado quando
    ! config_blend_bdy_terrain=.true., logo antes do bloco
    ! "if (config_vertical_grid) then" que contem a suavizacao de 4a ordem
    ! do terreno (a suavizacao ja implementada acima, em
    ! compute_vertical_grid, opera sobre o terreno JA misturado).
    !
    ! Diferenca deliberada do original: la', o terreno do first-guess vem
    ! de reler o campo SOILHGT direto de um arquivo binario intermediario
    ! WPS (projecao lat-lon) e reinterpolar bilinearmente (FOUR_POINT) pra
    ! cada celula de fronteira. Na rota nativa, SOILHGT ja foi interpolado
    ! baricentricamente pra cada celula da malha-alvo na Fase 1
    ! (hinterp_native, generico sobre todos os campos do first-guess ->
    ! native_target.nc) -- entao usamos esse valor diretamente, sem
    ! nenhuma reprojecao/reinterpolacao adicional (confirmado presente e
    ! com valores fisicamente plausiveis num native_target.nc real).
    !
    ! nBdyLayers/nSpecLayers sao constantes fixas no original (nao
    ! configuraveis via namelist) -- confirmadas batendo contra
    ! bdyMaskCell real da malha SouthAmerica (max=7, exatamente
    ! nBdyLayers=7).
    subroutine blend_bdy_terrain_native(nCells, bdyMaskCell, soilhgt_fg, ter)

        implicit none

        integer, intent(in) :: nCells
        integer, dimension(nCells), intent(in) :: bdyMaskCell
        real (kind=RKIND), dimension(nCells), intent(in) :: soilhgt_fg
        real (kind=RKIND), dimension(nCells), intent(inout) :: ter

        integer, parameter :: nBdyLayers = 7   ! camadas de relaxamento + especificadas
        integer, parameter :: nSpecLayers = 2  ! camadas especificadas (fronteira externa)

        integer :: iCell
        real (kind=RKIND) :: weight

        do iCell = 1, nCells
            if (bdyMaskCell(iCell) > 0) then
                if (bdyMaskCell(iCell) > (nBdyLayers - nSpecLayers)) then
                    ! Celula "especificada": terreno = first-guess direto, sem mistura.
                    ter(iCell) = soilhgt_fg(iCell)
                else
                    ! Celula de "relaxamento": combinacao ponderada, peso cresce
                    ! em direcao a fronteira (bdyMaskCell maior).
                    weight = real(bdyMaskCell(iCell), RKIND) / real(nBdyLayers - nSpecLayers, RKIND)
                    ter(iCell) = weight * soilhgt_fg(iCell) + (1.0_RKIND - weight) * ter(iCell)
                end if
            end if
        end do

    end subroutine blend_bdy_terrain_native


    !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    ! compute_zb
    !
    ! Termos de metrica pra advecao de 3a ordem de theta nas arestas
    ! (zb/zb3, usados so' na Fase 4, bloco de vento vertical diagnostico
    ! rw/w). Extraido literalmente de mpas_init_atm_cases.F (mpas-bundle-3.0.2,
    ! "For z-metric term in omega equation", ~linha 3335 dessa versao).
    !
    ! ACHADO 2026-09-09: ao contrario do que o plano original assumia
    ! ("zb/zb3 ja vem pronto no static.nc"), esses campos NAO existem em
    ! static.nc -- dependem de `zgrid` (saida desta Fase 2), entao tem que
    ! ser recalculados aqui, depois de compute_vertical_grid. `deriv_two`
    ! (coeficientes de 2a derivada horizontal, dimensao (1+maxEdges,2,nEdges)
    ! no static.nc, aqui declarado (maxEdges+1,2,nEdges)) esse sim ja vem
    ! pronto no static.nc, so' e' lido.
    !
    ! Convencao de vizinho ausente: "cellsOnCell(i,cell)>0" no original
    ! (framework MPAS usa 0 OU nCells+1 dependendo do contexto pra vizinho
    ! ausente -- aqui, mesma convencao ja estabelecida no resto deste
    ! projeto, vizinho ausente = 0, entao o teste ">0" ja funciona sem
    ! traducao). "cellsOnEdge==0" (aresta de borda com so' uma celula real)
    ! tratado como nos outros lugares deste modulo (zxu): substitui pela
    ! celula valida do outro lado.
    !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    subroutine compute_zb(nCells, nEdges, maxEdges, nVertLevels, &
                           nEdgesOnCell, cellsOnCell, cellsOnEdge, &
                           dvEdge, dcEdge, areaCell, deriv_two, zgrid, &
                           config_theta_adv_order, zb, zb3)

        implicit none

        integer, intent(in) :: nCells, nEdges, maxEdges, nVertLevels
        integer, dimension(nCells), intent(in) :: nEdgesOnCell
        integer, dimension(maxEdges,nCells), intent(in) :: cellsOnCell
        integer, dimension(2,nEdges), intent(in) :: cellsOnEdge
        real (kind=RKIND), dimension(nEdges), intent(in) :: dvEdge, dcEdge
        real (kind=RKIND), dimension(nCells), intent(in) :: areaCell
        real (kind=RKIND), dimension(maxEdges+1,2,nEdges), intent(in) :: deriv_two
        real (kind=RKIND), dimension(nVertLevels+1,nCells), intent(in) :: zgrid
        integer, intent(in) :: config_theta_adv_order

        real (kind=RKIND), dimension(nVertLevels+1,2,nEdges), intent(out) :: zb, zb3

        integer :: iEdge, iCell1, iCell2, i, k
        real (kind=RKIND) :: d2fdx2_cell1, d2fdx2_cell2, z_edge, z_edge3

        zb  = 0.0_RKIND
        zb3 = 0.0_RKIND

        do iEdge=1,nEdges
            iCell1 = cellsOnEdge(1,iEdge)
            iCell2 = cellsOnEdge(2,iEdge)
            if (iCell1 == 0) iCell1 = iCell2
            if (iCell2 == 0) iCell2 = iCell1

            do k=1,nVertLevels

                if (config_theta_adv_order == 2) then

                    z_edge = (zgrid(k,iCell1)+zgrid(k,iCell2))/2.0_RKIND
                    z_edge3 = 0.0_RKIND

                else

                    d2fdx2_cell1 = deriv_two(1,1,iEdge) * zgrid(k,iCell1)
                    d2fdx2_cell2 = deriv_two(1,2,iEdge) * zgrid(k,iCell2)
                    do i=1,nEdgesOnCell(iCell1)
                        if (cellsOnCell(i,iCell1) > 0) &
                            d2fdx2_cell1 = d2fdx2_cell1 + deriv_two(i+1,1,iEdge) * zgrid(k,cellsOnCell(i,iCell1))
                    end do
                    do i=1,nEdgesOnCell(iCell2)
                        if (cellsOnCell(i,iCell2) > 0) &
                            d2fdx2_cell2 = d2fdx2_cell2 + deriv_two(i+1,2,iEdge) * zgrid(k,cellsOnCell(i,iCell2))
                    end do

                    z_edge = 0.5_RKIND*(zgrid(k,iCell1)+zgrid(k,iCell2)) &
                             - (dcEdge(iEdge)**2) * (d2fdx2_cell1+d2fdx2_cell2) / 12.0_RKIND

                    if (config_theta_adv_order == 3) then
                        z_edge3 = -(dcEdge(iEdge)**2) * (d2fdx2_cell1-d2fdx2_cell2) / 12.0_RKIND
                    else
                        z_edge3 = 0.0_RKIND
                    end if

                end if

                zb (k,1,iEdge) = (z_edge-zgrid(k,iCell1))*dvEdge(iEdge)/areaCell(iCell1)
                zb (k,2,iEdge) = (z_edge-zgrid(k,iCell2))*dvEdge(iEdge)/areaCell(iCell2)
                zb3(k,1,iEdge) =  z_edge3*dvEdge(iEdge)/areaCell(iCell1)
                zb3(k,2,iEdge) =  z_edge3*dvEdge(iEdge)/areaCell(iCell2)

            end do
        end do

    end subroutine compute_zb


    !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    ! shapiro_pass
    !
    ! Uma passada do suavizador de terreno de 4a ordem usado antes da
    ! grade vertical (mesma formula pros dois sentidos, so' troca o sinal
    ! do coeficiente: +0.216 na primeira metade do par, -0.216 na segunda).
    !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    subroutine shapiro_pass(nCells, maxEdges, nEdgesOnCell, cellsOnCell, edgesOnCell, dvEdge, dcEdge, &
                             coef, field_in, field_out)

        implicit none

        integer, intent(in) :: nCells, maxEdges
        integer, dimension(nCells), intent(in) :: nEdgesOnCell
        integer, dimension(maxEdges,nCells), intent(in) :: cellsOnCell, edgesOnCell
        real (kind=SPKIND), dimension(:), intent(in) :: dvEdge, dcEdge
        real (kind=SPKIND), intent(in) :: coef
        real (kind=SPKIND), dimension(nCells), intent(in) :: field_in
        real (kind=SPKIND), dimension(nCells), intent(out) :: field_out

        integer :: iCell, j, nb
        real (kind=SPKIND) :: acc, nbval

        do iCell=1,nCells
            acc = 0.0_SPKIND
            if (field_in(iCell) /= 0.0_SPKIND) then
                do j=1,nEdgesOnCell(iCell)
                    nb = cellsOnCell(j,iCell)
                    if (nb == 0) then
                        nbval = field_in(iCell)
                    else
                        nbval = field_in(nb)
                    end if
                    acc = acc + dvEdge(edgesOnCell(j,iCell)) / dcEdge(edgesOnCell(j,iCell)) * (nbval - field_in(iCell))
                end do
            end if
            field_out(iCell) = field_in(iCell) + coef*acc
        end do

    end subroutine shapiro_pass

end module vertical_grid
