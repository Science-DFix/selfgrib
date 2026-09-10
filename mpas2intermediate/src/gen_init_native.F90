program gen_init_native

    ! Fases 3+4 do plano de interpolacao nativa Voronoi -- driver que liga
    ! a saida da Fase 1 (hinterp_native, campos ja na malha-alvo mas ainda
    ! em niveis de pressao fixos) + Fase 2 (vertical_grid, zgrid/zz/zb/zb3
    ! nativos da malha-alvo) aos novos modulos vinterp_native.F90 (Fase 3,
    ! interpolacao vertical pro zgrid) e hydrostatic.F90 (Fase 4, balanco
    ! hidrostatico/umidade/agua precipitavel/vento vertical).
    !
    ! Uso:
    !   gen_init_native malha-alvo.static.nc namelist.init_atmosphere native_target.nc saida.nc
    !
    ! config_* lidos do namelist.init_atmosphere REAL do experimento (via
    ! namelist_config.F90) -- reproduzivel pra qualquer malha/experimento/
    ! tempo (init OU cada lbc), nao so' o caso SouthAmerica usado como
    ! exemplo inicial (achado 2026-09-09, revisao pedida pelo usuario:
    ! antes desta versao, config_start_time/config_ztop/config_nsm/etc.
    ! ficavam fixos no codigo, exigindo recompilar por experimento --
    ! bloqueava inclusive o proprio lbc.*.nc, que muda config_start_time a
    ! cada tempo dentro do MESMO experimento).
    !
    ! config_hybrid_coordinate/config_hybrid_top_z sao excecao (mesma nota
    ! de gen_vertical_grid.F90): nao sao opcoes de namelist na 3.0.2,
    ! continuam fixos.

    use mpas_kind_types, only : RKIND
    use mpas_constants, only : gravity, rgas, cp
    use scan_input
    use vertical_grid
    use vinterp_native
    use hydrostatic
    use surface_fields
    use namelist_config
    use pressure_levels, only : N_PLEVELS, plevels_hPa
    use netcdf

    implicit none

    character (len=1024) :: mesh_filename, namelist_filename, fg_filename, output_filename
    type (input_handle_type) :: handle
    type (input_field_type) :: field
    type (init_atm_config_type) :: cfg

    integer :: nCells, nEdges, maxEdges, nVertLevels, extrap_airtemp
    logical, parameter :: config_hybrid_coordinate = .true.
    real (kind=RKIND), parameter :: config_hybrid_top_z = 30000.0_RKIND
    integer, parameter :: nSoilLevels = 4
    real (kind=RKIND), parameter :: dzs_const(nSoilLevels) = (/0.1_RKIND, 0.3_RKIND, 0.6_RKIND, 1.0_RKIND/)
    real (kind=RKIND), parameter :: zs_const(nSoilLevels)  = (/0.05_RKIND, 0.25_RKIND, 0.70_RKIND, 1.50_RKIND/)

    integer, dimension(:), allocatable :: nEdgesOnCell, bdyMaskCell
    integer, dimension(:,:), allocatable :: cellsOnCell, edgesOnCell, cellsOnEdge
    real (kind=RKIND), dimension(:), allocatable :: dvEdge, dcEdge, ter, ter_smoothed, areaCell, angleEdge
    real (kind=RKIND), dimension(:,:,:), allocatable :: deriv_two

    real (kind=RKIND), dimension(:,:), allocatable :: zgrid
    real (kind=RKIND), dimension(:,:), allocatable :: zz, dss
    real (kind=RKIND), dimension(:,:), allocatable :: zxu
    real (kind=RKIND), dimension(:), allocatable :: rdzw, dzu, rdzu, fzm, fzp
    real (kind=RKIND) :: cf1, cf2, cf3
    real (kind=RKIND), dimension(:,:,:), allocatable :: zb, zb3

    ! Campos do first-guess na malha-alvo (saida da Fase 1)
    real (kind=RKIND), dimension(:,:), allocatable :: fg_tt, fg_uu, fg_vv, fg_ght, fg_spechumd, fg_rh
    real (kind=RKIND), dimension(:), allocatable :: fg_tt_sfc, fg_uu_sfc, fg_vv_sfc, fg_spechumd_sfc, fg_rh_sfc, fg_psfc

    ! Saidas Fase 3
    real (kind=RKIND), dimension(:,:), allocatable :: t_out, relhum_out, spechum_out, pressure_out
    real (kind=RKIND), dimension(:,:), allocatable :: u_out
    real (kind=RKIND), dimension(:), allocatable :: psfc_out

    ! Saidas Fase 4
    real (kind=RKIND), dimension(:,:), allocatable :: qv, rho, theta, rho_base, theta_base, w, ru
    real (kind=RKIND), dimension(:), allocatable :: precipw, surface_pressure, q2

    ! Fase 6: campos de superficie/solo
    integer, dimension(:), allocatable :: landmask
    real (kind=RKIND), dimension(:), allocatable :: soiltemp
    real (kind=RKIND), dimension(:,:), allocatable :: greenfrac, albedo12m
    ! Item 3 (reclassificacao de gelo marinho): campos estaticos que ate'
    ! agora eram sempre de copia direta (static.nc -> init.nc via ncks -A,
    ! nunca lidos por este programa); passam a ser lidos/escritos aqui
    ! porque um numero pequeno de celulas pode precisar ser sobrescrito.
    integer, dimension(:), allocatable :: ivgtyp, isltyp
    real (kind=RKIND), dimension(:), allocatable :: snoalb
    integer :: isice_lu
    real (kind=RKIND), dimension(:), allocatable :: fg_skintemp, fg_soilhgt, fg_sst, fg_snow, fg_seaice_raw
    real (kind=RKIND), dimension(:,:), allocatable :: fg_smois, fg_tslb
    real (kind=RKIND), dimension(:), allocatable :: skintemp_out, tmn, snowc, snowh, xland, xice, seaice_out
    real (kind=RKIND), dimension(:), allocatable :: vegfra_out, sfc_albbck_out
    real (kind=RKIND), dimension(:,:), allocatable :: sh2o, dz_soil, dzs_out, zs_out
    real (kind=RKIND), dimension(:,:), allocatable :: tslb_out, smois_out
    real (kind=RKIND), dimension(:), allocatable :: u_init, v_init, qv_init, h_oml_initial
    real (kind=RKIND), dimension(:,:), allocatable :: t_init, qc, qr

    real (kind=RKIND), dimension(N_PLEVELS) :: p_fg_pa, log_p_fg_pa
    real (kind=RKIND), dimension(:), allocatable :: target_z_mid
    real (kind=RKIND), dimension(1) :: target_z_sfc, log_psfc_out
    real (kind=RKIND) :: xice_threshold

    integer :: stat, ncid, ncid_fg
    integer :: varid, dimid_nCells, dimid_nEdges, dimid_nVertLevels, dimid_nVertLevelsP1
    integer :: iCell, iEdge, k, ierr_local, cell1, cell2
    real (kind=RKIND) :: u_fg_edge_component, avg_z_edge
    real (kind=RKIND), dimension(N_PLEVELS) :: u_edge_profile

    if (command_argument_count() < 4) then
        write(0,*) 'Uso: gen_init_native malha-alvo.static.nc namelist.init_atmosphere native_target.nc saida.nc'
        stop 1
    end if
    call get_command_argument(1, mesh_filename)
    call get_command_argument(2, namelist_filename)
    call get_command_argument(3, fg_filename)
    call get_command_argument(4, output_filename)

    write(0,*) 'Lendo '''//trim(namelist_filename)//''''
    call read_init_atm_namelist(namelist_filename, cfg)
    nVertLevels = cfg % config_nvertlevels
    extrap_airtemp = extrap_airtemp_code(cfg % config_extrap_airtemp)
    if (cfg % config_nsoillevels /= nSoilLevels) then
        write(0,*) 'Error: config_nsoillevels deve ser 4 (NOAH LSM) -- achado ', cfg % config_nsoillevels
        stop 5
    end if
    write(0,*) '  config_start_time=', trim(cfg % config_start_time), &
               ' config_nvertlevels=', nVertLevels, ' config_blend_bdy_terrain=', cfg % config_blend_bdy_terrain

    !-----------------------------------------------------------------
    ! 1) Malha-alvo: conectividade (mesmo padrao de gen_vertical_grid.F90)
    !-----------------------------------------------------------------
    write(0,*) 'Lendo conectividade/terreno de '''//trim(mesh_filename)//''''
    if (scan_input_open(mesh_filename, handle) /= 0) then
        write(0,*) 'Error: nao consegui abrir '//trim(mesh_filename)
        stop 2
    end if

    stat = scan_input_for_field(handle, 'nEdgesOnCell', field)
    nCells = field % dimlens(1)
    stat = scan_input_read_field(field)
    allocate(nEdgesOnCell(nCells)); nEdgesOnCell = field % array1i
    stat = scan_input_free_field(field)

    stat = scan_input_for_field(handle, 'cellsOnCell', field)
    maxEdges = field % dimlens(1)
    stat = scan_input_read_field(field)
    allocate(cellsOnCell(maxEdges,nCells)); cellsOnCell = field % array2i
    stat = scan_input_free_field(field)

    stat = scan_input_for_field(handle, 'edgesOnCell', field)
    stat = scan_input_read_field(field)
    allocate(edgesOnCell(maxEdges,nCells)); edgesOnCell = field % array2i
    stat = scan_input_free_field(field)

    stat = scan_input_for_field(handle, 'cellsOnEdge', field)
    nEdges = field % dimlens(2)
    stat = scan_input_read_field(field)
    allocate(cellsOnEdge(2,nEdges)); cellsOnEdge = field % array2i
    stat = scan_input_free_field(field)

    stat = scan_input_for_field(handle, 'dvEdge', field)
    stat = scan_input_read_field(field)
    allocate(dvEdge(nEdges)); dvEdge = real(field % array1r, RKIND)
    stat = scan_input_free_field(field)

    stat = scan_input_for_field(handle, 'dcEdge', field)
    stat = scan_input_read_field(field)
    allocate(dcEdge(nEdges)); dcEdge = real(field % array1r, RKIND)
    stat = scan_input_free_field(field)

    stat = scan_input_for_field(handle, 'ter', field)
    stat = scan_input_read_field(field)
    allocate(ter(nCells)); ter = real(field % array1r, RKIND)
    stat = scan_input_free_field(field)

    stat = scan_input_for_field(handle, 'bdyMaskCell', field)
    stat = scan_input_read_field(field)
    allocate(bdyMaskCell(nCells)); bdyMaskCell = field % array1i
    stat = scan_input_free_field(field)

    stat = scan_input_for_field(handle, 'areaCell', field)
    stat = scan_input_read_field(field)
    allocate(areaCell(nCells)); areaCell = real(field % array1r, RKIND)
    stat = scan_input_free_field(field)

    stat = scan_input_for_field(handle, 'angleEdge', field)
    stat = scan_input_read_field(field)
    allocate(angleEdge(nEdges)); angleEdge = real(field % array1r, RKIND)
    stat = scan_input_free_field(field)

    ! Fase 6: campos estaticos de superficie (landmask/soiltemp/greenfrac/
    ! albedo12m) -- ja em static.nc, usados aqui so' pra CALCULAR os
    ! campos derivados (tmn/vegfra/sfc_albbck/etc); a copia direta dos
    ! ~81 campos puramente geometricos/estaticos pro init.nc final e' feita
    ! depois via 'ncks -A' (ver README/script de orquestracao), nao por
    ! este programa.
    stat = scan_input_for_field(handle, 'landmask', field)
    stat = scan_input_read_field(field)
    allocate(landmask(nCells)); landmask = field % array1i
    stat = scan_input_free_field(field)

    stat = scan_input_for_field(handle, 'soiltemp', field)
    stat = scan_input_read_field(field)
    allocate(soiltemp(nCells)); soiltemp = real(field % array1r, RKIND)
    stat = scan_input_free_field(field)

    stat = scan_input_for_field(handle, 'greenfrac', field)
    stat = scan_input_read_field(field)
    allocate(greenfrac(12,nCells)); greenfrac = real(field % array2r, RKIND)
    stat = scan_input_free_field(field)

    stat = scan_input_for_field(handle, 'albedo12m', field)
    stat = scan_input_read_field(field)
    allocate(albedo12m(12,nCells)); albedo12m = real(field % array2r, RKIND)
    stat = scan_input_free_field(field)

    ! Item 3: ivgtyp/isltyp/snoalb -- ate' aqui eram so' de copia direta
    ! (nunca lidos por este programa); agora lidos porque a reclassificacao
    ! de gelo marinho pode precisar sobrescreve-los pra um subconjunto de
    ! celulas.
    stat = scan_input_for_field(handle, 'ivgtyp', field)
    stat = scan_input_read_field(field)
    allocate(ivgtyp(nCells)); ivgtyp = field % array1i
    stat = scan_input_free_field(field)

    stat = scan_input_for_field(handle, 'isltyp', field)
    stat = scan_input_read_field(field)
    allocate(isltyp(nCells)); isltyp = field % array1i
    stat = scan_input_free_field(field)

    stat = scan_input_for_field(handle, 'snoalb', field)
    stat = scan_input_read_field(field)
    allocate(snoalb(nCells)); snoalb = real(field % array1r, RKIND)
    stat = scan_input_free_field(field)

    stat = scan_input_close(handle)

    ! deriv_two: 3D, fora do que scan_input suporta (maximo 2D) -- le
    ! direto via netCDF. A dimensao "FIFTEEN" do static.nc e' um limite
    ! generico do gerador de malha MPAS, nao necessariamente igual a
    ! maxEdges+1 desta malha especifica (aqui maxEdges=10 -> so' usamos
    ! as 11 primeiras entradas) -- le no tamanho real do arquivo e recorta.
    block
        integer :: dimid_fifteen, n_fifteen
        real (kind=RKIND), dimension(:,:,:), allocatable :: deriv_two_raw
        stat = nf90_open(trim(mesh_filename), NF90_NOWRITE, ncid)
        stat = nf90_inq_varid(ncid, 'deriv_two', varid)
        stat = nf90_inq_dimid(ncid, 'FIFTEEN', dimid_fifteen)
        stat = nf90_inquire_dimension(ncid, dimid_fifteen, len=n_fifteen)
        allocate(deriv_two_raw(n_fifteen,2,nEdges))
        stat = nf90_get_var(ncid, varid, deriv_two_raw)
        stat = nf90_close(ncid)
        allocate(deriv_two(maxEdges+1,2,nEdges))
        deriv_two = deriv_two_raw(1:maxEdges+1,:,:)
        deallocate(deriv_two_raw)
    end block

    ! isice_lu: variavel escalar (sem dimensao), fora do que scan_input
    ! suporta -- le direto via netCDF. Default 24 (Registry.xml,
    ! core_atmosphere/physics) se por algum motivo ausente do static.nc
    ! (nao deveria acontecer -- static.nc real sempre tem).
    block
        integer :: ncid_isice, varid_isice, stat_isice
        isice_lu = 24
        stat_isice = nf90_open(trim(mesh_filename), NF90_NOWRITE, ncid_isice)
        if (stat_isice == NF90_NOERR) then
            stat_isice = nf90_inq_varid(ncid_isice, 'isice_lu', varid_isice)
            if (stat_isice == NF90_NOERR) stat_isice = nf90_get_var(ncid_isice, varid_isice, isice_lu)
            stat_isice = nf90_close(ncid_isice)
        end if
    end block

    write(0,*) '  nCells=', nCells, ' nEdges=', nEdges, ' maxEdges=', maxEdges

    !-----------------------------------------------------------------
    ! 1b) Mistura de terreno de fronteira (config_blend_bdy_terrain) --
    ! item 1 do plano de fidelidade (doc_voronoi/PLANO_FIDELIDADE.md).
    ! Precisa do SOILHGT do first-guess ja' interpolado pela Fase 1
    ! (hinterp_native -> native_target.nc) -- leitura minima aqui, so'
    ! desse campo; a leitura completa do first-guess (secao 3, abaixo)
    ! re-le SOILHGT de novo pro calculo de skintemp -- redundante mas
    ! inofensivo (arquivo pequeno), evita reordenar todo o programa.
    !-----------------------------------------------------------------
    if (cfg % config_blend_bdy_terrain) then
        write(0,*) 'Misturando terreno de fronteira com first-guess (config_blend_bdy_terrain=true)'
        block
            integer :: ncid_soilhgt
            real (kind=RKIND), dimension(:), allocatable :: soilhgt_fg_early
            allocate(soilhgt_fg_early(nCells))
            stat = nf90_open(trim(fg_filename), NF90_NOWRITE, ncid_soilhgt)
            call read2d(ncid_soilhgt, 'SOILHGT', nCells, soilhgt_fg_early)
            stat = nf90_close(ncid_soilhgt)
            call blend_bdy_terrain_native(nCells, bdyMaskCell, soilhgt_fg_early, ter)
            deallocate(soilhgt_fg_early)
        end block
    end if

    !-----------------------------------------------------------------
    ! 2) Fase 2: grade vertical nativa + zb/zb3
    !-----------------------------------------------------------------
    allocate(zgrid(nVertLevels+1,nCells))
    allocate(zz(nVertLevels,nCells))
    allocate(dss(nVertLevels,nCells))
    allocate(zxu(nVertLevels,nEdges))
    allocate(zb(nVertLevels+1,2,nEdges))
    allocate(zb3(nVertLevels+1,2,nEdges))
    allocate(rdzw(nVertLevels), dzu(nVertLevels), rdzu(nVertLevels), fzm(nVertLevels), fzp(nVertLevels))
    allocate(target_z_mid(nVertLevels))
    allocate(ter_smoothed(nCells))

    write(0,*) 'Calculando grade vertical nativa (Fase 2)'
    call compute_vertical_grid(nCells, nEdges, maxEdges, nVertLevels, &
                                nEdgesOnCell, cellsOnCell, edgesOnCell, cellsOnEdge, &
                                dvEdge, dcEdge, ter, &
                                cfg % config_ztop, cfg % config_nsmterrain, cfg % config_nsm, cfg % config_dzmin, &
                                config_hybrid_coordinate, config_hybrid_top_z, &
                                cfg % config_smooth_surfaces, &
                                cfg % config_interface_projection, &
                                zgrid, zz, zxu, rdzw, dzu, rdzu, fzm, fzp, cf1, cf2, cf3, dss, &
                                ter_smoothed)

    write(0,*) 'Calculando zb/zb3'
    call compute_zb(nCells, nEdges, maxEdges, nVertLevels, &
                     nEdgesOnCell, cellsOnCell, cellsOnEdge, &
                     dvEdge, dcEdge, areaCell, deriv_two, zgrid, &
                     cfg % config_theta_adv_order, zb, zb3)

    !-----------------------------------------------------------------
    ! 3) Fase 1 (ja rodada): le native_target.nc
    !-----------------------------------------------------------------
    write(0,*) 'Lendo first-guess ja remapeado (Fase 1) de '''//trim(fg_filename)//''''
    allocate(fg_tt(N_PLEVELS,nCells), fg_uu(N_PLEVELS,nCells), fg_vv(N_PLEVELS,nCells))
    allocate(fg_ght(N_PLEVELS,nCells), fg_spechumd(N_PLEVELS,nCells), fg_rh(N_PLEVELS,nCells))
    allocate(fg_tt_sfc(nCells), fg_uu_sfc(nCells), fg_vv_sfc(nCells))
    allocate(fg_spechumd_sfc(nCells), fg_rh_sfc(nCells), fg_psfc(nCells))

    stat = nf90_open(trim(fg_filename), NF90_NOWRITE, ncid_fg)
    call read3d(ncid_fg, 'TT',       N_PLEVELS, nCells, fg_tt)
    call read3d(ncid_fg, 'UU',       N_PLEVELS, nCells, fg_uu)
    call read3d(ncid_fg, 'VV',       N_PLEVELS, nCells, fg_vv)
    call read3d(ncid_fg, 'GHT',      N_PLEVELS, nCells, fg_ght)
    call read3d(ncid_fg, 'SPECHUMD', N_PLEVELS, nCells, fg_spechumd)
    call read3d(ncid_fg, 'RH',       N_PLEVELS, nCells, fg_rh)
    call read2d(ncid_fg, 'TT_SFC',       nCells, fg_tt_sfc)
    call read2d(ncid_fg, 'UU_SFC',       nCells, fg_uu_sfc)
    call read2d(ncid_fg, 'VV_SFC',       nCells, fg_vv_sfc)
    call read2d(ncid_fg, 'SPECHUMD_SFC', nCells, fg_spechumd_sfc)
    call read2d(ncid_fg, 'RH_SFC',       nCells, fg_rh_sfc)
    call read2d(ncid_fg, 'PSFC',         nCells, fg_psfc)

    allocate(fg_skintemp(nCells), fg_soilhgt(nCells), fg_sst(nCells), fg_snow(nCells), fg_seaice_raw(nCells))
    call read2d(ncid_fg, 'SKINTEMP', nCells, fg_skintemp)
    call read2d(ncid_fg, 'SOILHGT',  nCells, fg_soilhgt)
    call read2d(ncid_fg, 'SST',      nCells, fg_sst)
    call read2d(ncid_fg, 'SNOW',     nCells, fg_snow)
    call read2d(ncid_fg, 'SEAICE',   nCells, fg_seaice_raw)

    allocate(fg_smois(nSoilLevels,nCells), fg_tslb(nSoilLevels,nCells))
    call read2d(ncid_fg, 'SM000010', nCells, fg_smois(1,:))
    call read2d(ncid_fg, 'SM010040', nCells, fg_smois(2,:))
    call read2d(ncid_fg, 'SM040100', nCells, fg_smois(3,:))
    call read2d(ncid_fg, 'SM100200', nCells, fg_smois(4,:))
    call read2d(ncid_fg, 'ST000010', nCells, fg_tslb(1,:))
    call read2d(ncid_fg, 'ST010040', nCells, fg_tslb(2,:))
    call read2d(ncid_fg, 'ST040100', nCells, fg_tslb(3,:))
    call read2d(ncid_fg, 'ST100200', nCells, fg_tslb(4,:))

    stat = nf90_close(ncid_fg)

    !-----------------------------------------------------------------
    ! 4) Fase 3: interpolacao vertical pro zgrid nativo
    !-----------------------------------------------------------------
    write(0,*) 'Fase 3: interpolacao vertical'
    allocate(t_out(nVertLevels,nCells), relhum_out(nVertLevels,nCells))
    allocate(spechum_out(nVertLevels,nCells), pressure_out(nVertLevels,nCells))
    allocate(u_out(nVertLevels,nEdges))
    allocate(psfc_out(nCells))

    p_fg_pa = plevels_hPa * 100.0_RKIND
    log_p_fg_pa = log(p_fg_pa)

    do iCell=1,nCells
        do k=1,nVertLevels
            target_z_mid(k) = 0.5_RKIND*(zgrid(k,iCell)+zgrid(k+1,iCell))
        end do

        call interp_column_to_layers(N_PLEVELS, fg_ght(:,iCell), fg_tt(:,iCell), &
                                      nVertLevels, target_z_mid, extrap_airtemp, t_out(:,iCell), ierr_local)
        call interp_column_to_layers(N_PLEVELS, fg_ght(:,iCell), fg_rh(:,iCell), &
                                      nVertLevels, target_z_mid, 0, relhum_out(:,iCell))
        call interp_column_to_layers(N_PLEVELS, fg_ght(:,iCell), max(0.0_RKIND,fg_spechumd(:,iCell)), &
                                      nVertLevels, target_z_mid, 0, spechum_out(:,iCell))
        call interp_column_to_layers(N_PLEVELS, fg_ght(:,iCell), log_p_fg_pa, &
                                      nVertLevels, target_z_mid, 1, pressure_out(:,iCell))
        pressure_out(:,iCell) = exp(pressure_out(:,iCell))

        target_z_sfc(1) = zgrid(1,iCell)
        call interp_column_to_layers(N_PLEVELS, fg_ght(:,iCell), log_p_fg_pa, &
                                      1, target_z_sfc, 1, log_psfc_out)
        psfc_out(iCell) = exp(log_psfc_out(1))
    end do

    do iEdge=1,nEdges
        cell1 = cellsOnEdge(1,iEdge); cell2 = cellsOnEdge(2,iEdge)
        if (cell1 == 0) cell1 = cell2
        if (cell2 == 0) cell2 = cell1
        do k=1,N_PLEVELS
            u_fg_edge_component = cos(angleEdge(iEdge)) * 0.5_RKIND*(fg_uu(k,cell1)+fg_uu(k,cell2)) &
                                 + sin(angleEdge(iEdge)) * 0.5_RKIND*(fg_vv(k,cell1)+fg_vv(k,cell2))
            u_edge_profile(k) = u_fg_edge_component
        end do
        do k=1,nVertLevels
            target_z_mid(k) = 0.25_RKIND*(zgrid(k,cell1)+zgrid(k+1,cell1)+zgrid(k,cell2)+zgrid(k+1,cell2))
        end do
        block
            real (kind=RKIND), dimension(N_PLEVELS) :: z_edge_profile
            do k=1,N_PLEVELS
                z_edge_profile(k) = 0.5_RKIND*(fg_ght(k,cell1)+fg_ght(k,cell2))
            end do
            call interp_column_to_layers(N_PLEVELS, z_edge_profile, u_edge_profile, &
                                          nVertLevels, target_z_mid, 0, u_out(:,iEdge))
        end block
    end do

    !-----------------------------------------------------------------
    ! 5) Fase 4: balanco hidrostatico
    !-----------------------------------------------------------------
    write(0,*) 'Fase 4: balanco hidrostatico'
    allocate(qv(nVertLevels,nCells))
    if (cfg % config_use_spechumd) then
        qv = spechum_out / (1.0_RKIND - spechum_out)
    else
        ! config_use_spechumd=false: qv derivado de RH via rslf (nao
        ! implementado -- todos os experimentos rodados ate agora usam
        ! config_use_spechumd=true; ver plano/README se isso precisar
        ! mudar).
        write(0,*) 'Error: config_use_spechumd=false nao implementado (qv via RH/rslf)'
        stop 6
    end if

    call convert_relhum_wrt_ice(nVertLevels, nCells, t_out, relhum_out)

    allocate(q2(nCells))
    call compute_q2(nCells, fg_tt_sfc, psfc_out, fg_rh_sfc, q2)

    allocate(rho(nVertLevels,nCells), theta(nVertLevels,nCells))
    allocate(rho_base(nVertLevels,nCells), theta_base(nVertLevels,nCells))
    allocate(w(nVertLevels+1,nCells), ru(nVertLevels,nEdges))
    allocate(precipw(nCells), surface_pressure(nCells))

    call compute_hydrostatic_balance(nCells, nEdges, maxEdges, nVertLevels, nVertLevels+1, &
                                      nEdgesOnCell, edgesOnCell, cellsOnEdge, &
                                      zgrid, zz, zb, zb3, fzm, fzp, dzu, rdzw, &
                                      cfg % config_theta_adv_order, cfg % config_coef_3rd_order, &
                                      pressure_out, t_out, qv, u_out, &
                                      rho, theta, rho_base, theta_base, precipw, w, ru, surface_pressure)

    !-----------------------------------------------------------------
    ! 5b) Fase 6: campos de superficie/solo (mpas_atmphys_initialize_real.F)
    !-----------------------------------------------------------------
    write(0,*) 'Fase 6: campos de superficie/solo'

    allocate(xland(nCells))
    where (landmask == 1)
        xland = 1.0_RKIND
    elsewhere
        xland = 2.0_RKIND
    end where

    ! skintemp/tmn corrigidos por lapso termico (diferenca de elevacao
    ! entre a orografia do first-guess, SOILHGT, e o terreno real da
    ! malha-alvo). Usa ter_smoothed (terreno JA' suavizado por
    ! compute_vertical_grid), nao ter cru -- achado 2026-09-09 (item 2 do
    ! plano de fidelidade): o original usa a MESMA variavel de terreno
    ! (ja' suavizada) em todo lugar, nos usavamos o cru aqui antes de
    ! ter_smoothed existir (ver nota em vertical_grid.F90).
    allocate(skintemp_out(nCells))
    skintemp_out = fg_skintemp - 0.0065_RKIND * (ter_smoothed - fg_soilhgt)

    allocate(tmn(nCells))
    where (landmask == 1)
        tmn = soiltemp - 0.0065_RKIND * ter_smoothed
    elsewhere
        tmn = skintemp_out
    end where

    allocate(sh2o(nSoilLevels,nCells))
    do iCell=1,nCells
        if (landmask(iCell) == 1) then
            sh2o(:,iCell) = 0.0_RKIND
        else
            sh2o(:,iCell) = 1.0_RKIND
        end if
    end do

    ! tslb/smois: item 2 do plano de fidelidade
    ! (doc_voronoi/PLANO_FIDELIDADE.md). Antes so' copiava fg_tslb/fg_smois
    ! direto; agora aplica a MESMA correcao de lapso termico ja' usada em
    ! skintemp/tmn (acima) ao perfil de solo inteiro (adjust_soil_lapse_rate,
    ! extraido de adjust_input_soiltemps) e reamostra pras profundidades-
    ! padrao Noah do alvo (resample_soil_profile, extraido de
    ! init_soil_layers_depth+properties) -- chamada logo apos zs_out ser
    ! calculado, abaixo. Com origem/destino usando as mesmas 4
    ! profundidades-padrao (caso MPAS-A -> MPAS-A validado), a reamostragem
    ! degenera matematicamente em identidade sobre o perfil JA corrigido
    ! por lapso -- ou seja, a unica mudanca real de resultado aqui e' a
    ! correcao de lapso, que antes faltava.
    call adjust_soil_lapse_rate(nCells, nSoilLevels, landmask, ter_smoothed, fg_soilhgt, fg_tslb)

    allocate(snowc(nCells), snowh(nCells))
    where (fg_snow >= 10.0_RKIND)
        snowc = 1.0_RKIND
    elsewhere
        snowc = 0.0_RKIND
    end where
    snowh = fg_snow * 5.0_RKIND / 1000.0_RKIND

    ! xice (limiar inicial, physics_init_sst/physics_init_seaice):
    ! config_frac_seaice do namelist real decide o limiar -- 0.5 (binariza
    ! direto o SEAICE bruto) se false, 0.02 (mantem fracionario) se true.
    ! seaice_out (flag final) e' derivado so' depois, dentro de
    ! reclassify_seaice (item 3, abaixo) -- que tambem faz a
    ! reclassificacao em cascata (ivgtyp/isltyp/snoalb/tslb/smois) de
    ! celulas de agua muito fria em gelo/terra. Irrelevante pro caso
    ! SouthAmerica (SEAICE do first-guess e' zero em toda a malha,
    ! confirmado contra o dado real), mas necessario pra malhas em alta
    ! latitude.
    allocate(xice(nCells), seaice_out(nCells))
    if (cfg % config_frac_seaice) then
        xice_threshold = 0.02_RKIND
        xice = fg_seaice_raw
    else
        xice_threshold = 0.5_RKIND
        where (fg_seaice_raw >= 0.5_RKIND)
            xice = 1.0_RKIND
        elsewhere
            xice = 0.0_RKIND
        end where
    end if
    where (xice < xice_threshold) xice = 0.0_RKIND

    allocate(vegfra_out(nCells), sfc_albbck_out(nCells))
    call monthly_interp_to_date(nCells, cfg % start_year, cfg % start_month, cfg % start_day, greenfrac, vegfra_out)
    call monthly_interp_to_date(nCells, cfg % start_year, cfg % start_month, cfg % start_day, albedo12m, sfc_albbck_out)
    sfc_albbck_out = sfc_albbck_out / 100.0_RKIND
    where (landmask == 0) sfc_albbck_out = 0.08_RKIND

    ! Campos sempre zero pro caso real-data (confirmado contra o init.nc
    ! real -- so' usados em casos idealizados que nao passam por
    ! init_atm_case_gfs).
    allocate(u_init(nVertLevels), v_init(nVertLevels), qv_init(nVertLevels))
    allocate(t_init(nVertLevels,nCells), h_oml_initial(nCells))
    allocate(dz_soil(nSoilLevels,nCells), qc(nVertLevels,nCells), qr(nVertLevels,nCells))
    u_init = 0.0_RKIND; v_init = 0.0_RKIND; qv_init = 0.0_RKIND
    t_init = 0.0_RKIND; h_oml_initial = 0.0_RKIND; dz_soil = 0.0_RKIND
    qc = 0.0_RKIND; qr = 0.0_RKIND

    ! dzs/zs: geometria fixa das 4 camadas de solo Noah, igual em toda celula.
    allocate(dzs_out(nSoilLevels,nCells), zs_out(nSoilLevels,nCells))
    do iCell=1,nCells
        dzs_out(:,iCell) = dzs_const
        zs_out(:,iCell)  = zs_const
    end do

    ! Reamostragem do perfil de solo (item 2, continuacao -- ver nota
    ! acima). dzs_fg_cm_const: profundidades-padrao Noah do FIRST-GUESS,
    ! em cm -- fixas porque extract_fields.F90 sempre emite
    ! SM000010/.../ST100200 nessa convencao (10/40/100/200cm cumulativo),
    ! valida so' quando a fonte tambem e' MPAS-A com o esquema Noah padrao
    ! (mesma limitacao ja documentada no relatorio tecnico).
    block
        real (kind=RKIND), parameter :: dzs_fg_cm_const(nSoilLevels) = (/10.0_RKIND, 30.0_RKIND, 60.0_RKIND, 100.0_RKIND/)
        allocate(tslb_out(nSoilLevels,nCells), smois_out(nSoilLevels,nCells))
        call resample_soil_profile(nCells, nSoilLevels, nSoilLevels, dzs_fg_cm_const, &
                                    fg_tslb, fg_smois, skintemp_out, tmn, zs_out, tslb_out, smois_out)
    end block

    ! Item 3 do plano de fidelidade: reclassificacao de gelo marinho
    ! (physics_init_sst + physics_init_seaice). Precisa rodar DEPOIS de
    ! skintemp_out/tmn/vegfra_out/tslb_out/smois_out/sh2o ja calculados
    ! (pode sobrescrever todos eles pra um subconjunto de celulas) e ANTES
    ! da escrita do arquivo. No caso validado (SouthAmerica, SEAICE do
    ! first-guess identicamente zero em toda a malha) nenhuma celula deve
    ! satisfazer o criterio de reclassificacao -- ver validacao no plano
    ! de fidelidade.
    call reclassify_seaice(nCells, nSoilLevels, landmask, isice_lu, &
                            cfg % config_input_sst, xice_threshold, cfg % config_tsk_seaice_threshold, fg_sst, &
                            xice, skintemp_out, tmn, ivgtyp, isltyp, snoalb, &
                            vegfra_out, xland, tslb_out, smois_out, sh2o, seaice_out)

    !-----------------------------------------------------------------
    ! 6) Escreve saida
    !-----------------------------------------------------------------
    write(0,*) 'Escrevendo '''//trim(output_filename)//''''
    stat = nf90_create(output_filename, NF90_CLOBBER, ncid)
    stat = nf90_def_dim(ncid, 'nCells', nCells, dimid_nCells)
    stat = nf90_def_dim(ncid, 'nEdges', nEdges, dimid_nEdges)
    stat = nf90_def_dim(ncid, 'nVertLevels', nVertLevels, dimid_nVertLevels)
    stat = nf90_def_dim(ncid, 'nVertLevelsP1', nVertLevels+1, dimid_nVertLevelsP1)
    block
        integer :: dimid_nSoilLevels
        stat = nf90_def_dim(ncid, 'nSoilLevels', nSoilLevels, dimid_nSoilLevels)
        call defvar1(ncid, 'skintemp', dimid_nCells)
        call defvar1(ncid, 'tmn', dimid_nCells)
        call defvar1(ncid, 'xland', dimid_nCells)
        call defvar1(ncid, 'xice', dimid_nCells)
        call defvar1(ncid, 'seaice', dimid_nCells)
        call defvar1_int(ncid, 'ivgtyp', dimid_nCells)
        call defvar1_int(ncid, 'isltyp', dimid_nCells)
        call defvar1(ncid, 'snoalb', dimid_nCells)
        call defvar1(ncid, 'snowc', dimid_nCells)
        call defvar1(ncid, 'snowh', dimid_nCells)
        call defvar1(ncid, 'snow', dimid_nCells)
        call defvar1(ncid, 'vegfra', dimid_nCells)
        call defvar1(ncid, 'sfc_albbck', dimid_nCells)
        call defvar1(ncid, 'sst', dimid_nCells)
        call defvar1(ncid, 't2m', dimid_nCells)
        call defvar1(ncid, 'u10', dimid_nCells)
        call defvar1(ncid, 'v10', dimid_nCells)
        call defvar1(ncid, 'rh2', dimid_nCells)
        call defvar1(ncid, 'h_oml_initial', dimid_nCells)
        call defvar2(ncid, 'sh2o', dimid_nSoilLevels, dimid_nCells)
        call defvar2(ncid, 'dz',   dimid_nSoilLevels, dimid_nCells)
        call defvar2(ncid, 'dzs',  dimid_nSoilLevels, dimid_nCells)
        call defvar2(ncid, 'zs',   dimid_nSoilLevels, dimid_nCells)
        call defvar2(ncid, 'smois', dimid_nSoilLevels, dimid_nCells)
        call defvar2(ncid, 'tslb',  dimid_nSoilLevels, dimid_nCells)
        call defvar1(ncid, 'u_init', dimid_nVertLevels)
        call defvar1(ncid, 'v_init', dimid_nVertLevels)
        call defvar1(ncid, 'qv_init', dimid_nVertLevels)
        call defvar2(ncid, 't_init', dimid_nVertLevels, dimid_nCells)
        call defvar2(ncid, 'qc', dimid_nVertLevels, dimid_nCells)
        call defvar2(ncid, 'qr', dimid_nVertLevels, dimid_nCells)
    end block

    call defvar2(ncid, 'rho',   dimid_nVertLevels, dimid_nCells)
    call defvar2(ncid, 'theta', dimid_nVertLevels, dimid_nCells)
    call defvar2(ncid, 'rho_base',   dimid_nVertLevels, dimid_nCells)
    call defvar2(ncid, 'theta_base', dimid_nVertLevels, dimid_nCells)
    call defvar2(ncid, 'qv',     dimid_nVertLevels, dimid_nCells)
    call defvar2(ncid, 'relhum', dimid_nVertLevels, dimid_nCells)
    call defvar2(ncid, 'w', dimid_nVertLevelsP1, dimid_nCells)
    call defvar2(ncid, 'u', dimid_nVertLevels, dimid_nEdges)
    call defvar1(ncid, 'precipw', dimid_nCells)
    call defvar1(ncid, 'surface_pressure', dimid_nCells)
    call defvar1(ncid, 'psfc', dimid_nCells)
    call defvar1(ncid, 'q2', dimid_nCells)

    ! Saida basica da Fase 2 (compute_vertical_grid) -- faltava escrever
    ! (achado 2026-09-09 comparando a contagem de variaveis do arquivo
    ! final contra o init.nc real).
    call defvar2(ncid, 'zgrid', dimid_nVertLevelsP1, dimid_nCells)
    call defvar2(ncid, 'zz',    dimid_nVertLevels,   dimid_nCells)
    call defvar2(ncid, 'dss',   dimid_nVertLevels,   dimid_nCells)
    call defvar2(ncid, 'zxu',   dimid_nVertLevels,   dimid_nEdges)
    call defvar1(ncid, 'rdzw', dimid_nVertLevels)
    call defvar1(ncid, 'dzu',  dimid_nVertLevels)
    call defvar1(ncid, 'rdzu', dimid_nVertLevels)
    call defvar1(ncid, 'fzm',  dimid_nVertLevels)
    call defvar1(ncid, 'fzp',  dimid_nVertLevels)

    block
        integer :: dimid_two, vid_zb, vid_zb3, vid_cf1, vid_cf2, vid_cf3, vid_it, vid_xtime
        integer :: dimid_strlen, dimid_time
        character (len=64) :: xtime_str
        stat = nf90_def_dim(ncid, 'TWO', 2, dimid_two)
        stat = nf90_def_var(ncid, 'zb',  NF90_DOUBLE, (/dimid_nVertLevels,dimid_two,dimid_nEdges/), vid_zb)
        stat = nf90_def_var(ncid, 'zb3', NF90_DOUBLE, (/dimid_nVertLevels,dimid_two,dimid_nEdges/), vid_zb3)
        stat = nf90_def_var(ncid, 'cf1', NF90_DOUBLE, vid_cf1)
        stat = nf90_def_var(ncid, 'cf2', NF90_DOUBLE, vid_cf2)
        stat = nf90_def_var(ncid, 'cf3', NF90_DOUBLE, vid_cf3)
        stat = nf90_def_dim(ncid, 'StrLen', 64, dimid_strlen)
        stat = nf90_def_var(ncid, 'initial_time', NF90_CHAR, (/dimid_strlen/), vid_it)
        ! xtime(Time,StrLen): achado 2026-09-09 rodando o mpas_atmosphere de
        ! verdade no Jaci -- faltava essa variavel (existe no init.nc real,
        ! vista na lista de 135 variaveis mas nao percebida como faltando
        ! na primeira leitura). E' o xtime, NAO o initial_time, que o
        ! mpas_atmosphere usa pra confirmar que o arquivo contem o tempo
        ! pedido em config_start_time -- sem ela, "ERROR: File ... does not
        ! contain the time ...". Mesmo dado do initial_time, so' que
        ! Time-dependente (igual ao xtime ja escrito em gen_lbc_native.F90,
        ! que sempre funcionou).
        stat = nf90_def_dim(ncid, 'Time', 1, dimid_time)
        stat = nf90_def_var(ncid, 'xtime', NF90_CHAR, (/dimid_strlen,dimid_time/), vid_xtime)
        stat = nf90_enddef(ncid)
        stat = nf90_put_var(ncid, vid_zb,  zb(1:nVertLevels,:,:))
        stat = nf90_put_var(ncid, vid_zb3, zb3(1:nVertLevels,:,:))
        stat = nf90_put_var(ncid, vid_cf1, cf1)
        stat = nf90_put_var(ncid, vid_cf2, cf2)
        stat = nf90_put_var(ncid, vid_cf3, cf3)
        xtime_str = trim(cfg % config_start_time)//'.0000'
        stat = nf90_put_var(ncid, vid_it, xtime_str)
        stat = nf90_put_var(ncid, vid_xtime, xtime_str, start=(/1,1/), count=(/64,1/))
    end block

    call putvar2(ncid, 'zgrid', zgrid)
    call putvar2(ncid, 'zz', zz)
    call putvar2(ncid, 'dss', dss)
    call putvar2(ncid, 'zxu', zxu)
    call putvar1(ncid, 'rdzw', rdzw)
    call putvar1(ncid, 'dzu', dzu)
    call putvar1(ncid, 'rdzu', rdzu)
    call putvar1(ncid, 'fzm', fzm)
    call putvar1(ncid, 'fzp', fzp)

    call putvar2(ncid, 'rho', rho)
    call putvar2(ncid, 'theta', theta)
    call putvar2(ncid, 'rho_base', rho_base)
    call putvar2(ncid, 'theta_base', theta_base)
    call putvar2(ncid, 'qv', qv)
    call putvar2(ncid, 'relhum', relhum_out)
    call putvar2(ncid, 'w', w)
    call putvar2(ncid, 'u', u_out)
    call putvar1(ncid, 'precipw', precipw)
    call putvar1(ncid, 'surface_pressure', surface_pressure)
    call putvar1(ncid, 'psfc', psfc_out)
    call putvar1(ncid, 'q2', q2)

    call putvar1(ncid, 'skintemp', skintemp_out)
    call putvar1(ncid, 'tmn', tmn)
    call putvar1(ncid, 'xland', xland)
    call putvar1(ncid, 'xice', xice)
    call putvar1(ncid, 'seaice', seaice_out)
    call putvar1_int(ncid, 'ivgtyp', ivgtyp)
    call putvar1_int(ncid, 'isltyp', isltyp)
    call putvar1(ncid, 'snoalb', snoalb)
    call putvar1(ncid, 'snowc', snowc)
    call putvar1(ncid, 'snowh', snowh)
    call putvar1(ncid, 'snow', fg_snow)
    call putvar1(ncid, 'vegfra', vegfra_out)
    call putvar1(ncid, 'sfc_albbck', sfc_albbck_out)
    call putvar1(ncid, 'sst', fg_sst)
    call putvar1(ncid, 't2m', fg_tt_sfc)
    call putvar1(ncid, 'u10', fg_uu_sfc)
    call putvar1(ncid, 'v10', fg_vv_sfc)
    call putvar1(ncid, 'rh2', fg_rh_sfc)
    call putvar1(ncid, 'h_oml_initial', h_oml_initial)
    call putvar2(ncid, 'sh2o', sh2o)
    call putvar2(ncid, 'dz', dz_soil)
    call putvar2(ncid, 'dzs', dzs_out)
    call putvar2(ncid, 'zs', zs_out)
    call putvar2(ncid, 'smois', smois_out)
    call putvar2(ncid, 'tslb', tslb_out)
    call putvar1(ncid, 'u_init', u_init)
    call putvar1(ncid, 'v_init', v_init)
    call putvar1(ncid, 'qv_init', qv_init)
    call putvar2(ncid, 't_init', t_init)
    call putvar2(ncid, 'qc', qc)
    call putvar2(ncid, 'qr', qr)

    stat = nf90_close(ncid)
    write(0,*) 'Pronto.'

    contains

    subroutine read3d(nc_id, name, n1, n2, arr)
        ! arr(n1,n2) = arr(N_PLEVELS,nCells) na convencao usada pelo resto
        ! deste programa, mas o arquivo entrega naturalmente (nCells,
        ! N_PLEVELS) -- dims do NetCDF (Time,nPressureLevels,latitude,
        ! longitude) vistas em Fortran como (longitude,latitude,
        ! nPressureLevels,Time), com latitude/Time=1 espremidos pelo
        ! nf90_get_var. Le num buffer temporario nessa ordem natural e
        ! transpoe.
        integer, intent(in) :: nc_id, n1, n2
        character(len=*), intent(in) :: name
        real (kind=RKIND), dimension(n1,n2), intent(out) :: arr
        real (kind=RKIND), dimension(n2,n1) :: buf
        integer :: vid, ist
        ist = nf90_inq_varid(nc_id, name, vid)
        ist = nf90_get_var(nc_id, vid, buf, start=(/1,1,1,1/), count=(/n2,1,n1,1/))
        arr = transpose(buf)
    end subroutine read3d

    subroutine read2d(nc_id, name, n1, arr)
        integer, intent(in) :: nc_id, n1
        character(len=*), intent(in) :: name
        real (kind=RKIND), dimension(n1), intent(out) :: arr
        integer :: vid, ist
        ist = nf90_inq_varid(nc_id, name, vid)
        ist = nf90_get_var(nc_id, vid, arr, start=(/1,1,1/), count=(/n1,1,1/))
    end subroutine read2d

    subroutine defvar1(nc_id, name, d1)
        integer, intent(in) :: nc_id, d1
        character(len=*), intent(in) :: name
        integer :: vid, ist
        ist = nf90_def_var(nc_id, name, NF90_DOUBLE, (/d1/), vid)
    end subroutine defvar1

    ! Item 3: ivgtyp/isltyp sao inteiros no init.nc real (nf90_get_var,
    ! confirmado contra o arquivo real -- ver plano de fidelidade), nao
    ! double como todo o resto que este programa escreve ate' agora.
    subroutine defvar1_int(nc_id, name, d1)
        integer, intent(in) :: nc_id, d1
        character(len=*), intent(in) :: name
        integer :: vid, ist
        ist = nf90_def_var(nc_id, name, NF90_INT, (/d1/), vid)
    end subroutine defvar1_int

    subroutine defvar2(nc_id, name, d1, d2)
        integer, intent(in) :: nc_id, d1, d2
        character(len=*), intent(in) :: name
        integer :: vid, ist
        ist = nf90_def_var(nc_id, name, NF90_DOUBLE, (/d1,d2/), vid)
    end subroutine defvar2

    subroutine putvar1(nc_id, name, arr)
        integer, intent(in) :: nc_id
        character(len=*), intent(in) :: name
        real (kind=RKIND), dimension(:), intent(in) :: arr
        integer :: vid, ist
        ist = nf90_inq_varid(nc_id, name, vid)
        ist = nf90_put_var(nc_id, vid, arr)
    end subroutine putvar1

    subroutine putvar1_int(nc_id, name, arr)
        integer, intent(in) :: nc_id
        character(len=*), intent(in) :: name
        integer, dimension(:), intent(in) :: arr
        integer :: vid, ist
        ist = nf90_inq_varid(nc_id, name, vid)
        ist = nf90_put_var(nc_id, vid, arr)
    end subroutine putvar1_int

    subroutine putvar2(nc_id, name, arr)
        integer, intent(in) :: nc_id
        character(len=*), intent(in) :: name
        real (kind=RKIND), dimension(:,:), intent(in) :: arr
        integer :: vid, ist
        ist = nf90_inq_varid(nc_id, name, vid)
        ist = nf90_put_var(nc_id, vid, arr)
    end subroutine putvar2

end program gen_init_native
