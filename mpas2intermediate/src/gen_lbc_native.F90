program gen_lbc_native

    ! Fase 7 (lbc.*.nc) do plano de interpolacao nativa Voronoi -- roda
    ! Fase 3 (vinterp_native, interpolacao vertical) + Fase 4 (hydrostatic,
    ! balanco hidrostatico) pra UM tempo de fronteira lateral, reusando a
    ! grade vertical nativa (zgrid/zz/zb/zb3/fzm/fzp/dzu/rdzw) e a
    ! conectividade da malha JA CALCULADAS pelo gen_init_native (lidas do
    ! init.nc completo, nao recalculadas) -- mesma logica do
    ! init_atm_case_lbc real, que reusa a malha do init.nc sem regenerar.
    !
    ! Schema de saida confirmado contra lbc.*.nc reais de producao
    ! (/mnt/dados2/ungrib_to_mpas/recortes/SouthAmerica/lbc_run/): so' 7
    ! campos prognosticos com prefixo 'lbc_' (lbc_qv/qc/qr/u/w/rho/theta),
    ! sem geometria/grade vertical (essas vem do stream 'input' = o
    ! init.nc, no MPAS real) -- um arquivo por tempo (Time=1 cada, nao
    ! concatenado).
    !
    ! Uso:
    !   gen_lbc_native init_completo.nc namelist.init_atmosphere native_target.nc saida_lbc.nc
    !
    !   init_completo.nc -- saida de gen_init_native + ncks -A (tem a
    !                        malha vertical E a conectividade, tudo que
    !                        este programa precisa, sem recalcular nada).
    !   namelist.init_atmosphere -- do EXPERIMENTO (idealmente o do
    !                        lbc_run, com config_start_time do tempo
    !                        sendo gerado -- config_blend_bdy_terrain=false
    !                        la', mas nao muda nada aqui, ja que blending
    !                        de terreno nao e' implementado nem no
    !                        init_run).
    !   native_target.nc -- saida da Fase 1 (hinterp_native) pro MESMO
    !                        tempo/first-guess deste arquivo lbc.

    use mpas_kind_types, only : RKIND
    use vinterp_native
    use hydrostatic
    use namelist_config
    use pressure_levels, only : N_PLEVELS, plevels_hPa
    use netcdf

    implicit none

    character (len=1024) :: init_filename, namelist_filename, fg_filename, output_filename
    type (init_atm_config_type) :: cfg

    integer :: nCells, nEdges, maxEdges, nVertLevels, extrap_airtemp
    integer :: ncid, ncid_fg, stat, varid
    integer :: iCell, iEdge, k, ierr_local, cell1, cell2

    integer, dimension(:,:), allocatable :: cellsOnEdge, edgesOnCell
    integer, dimension(:), allocatable :: nEdgesOnCell
    real (kind=RKIND), dimension(:), allocatable :: dvEdge, dcEdge, angleEdge
    real (kind=RKIND), dimension(:,:), allocatable :: zgrid, zz
    real (kind=RKIND), dimension(:,:,:), allocatable :: zb, zb3
    real (kind=RKIND), dimension(:), allocatable :: fzm, fzp, dzu, rdzw

    real (kind=RKIND), dimension(:,:), allocatable :: fg_tt, fg_uu, fg_vv, fg_ght, fg_spechumd, fg_rh
    real (kind=RKIND), dimension(:), allocatable :: fg_tt_sfc, fg_rh_sfc

    real (kind=RKIND), dimension(:,:), allocatable :: t_out, relhum_out, spechum_out, pressure_out, u_out
    real (kind=RKIND), dimension(:), allocatable :: psfc_out

    real (kind=RKIND), dimension(:,:), allocatable :: qv, rho, theta, rho_base, theta_base, w, ru, qc, qr
    real (kind=RKIND), dimension(:), allocatable :: precipw, surface_pressure, q2

    real (kind=RKIND), dimension(N_PLEVELS) :: p_fg_pa, log_p_fg_pa, u_edge_profile
    real (kind=RKIND), dimension(:), allocatable :: target_z_mid
    real (kind=RKIND), dimension(1) :: target_z_sfc, log_psfc_out
    real (kind=RKIND) :: u_fg_edge_component

    integer :: dimid_nCells, dimid_nEdges, dimid_nVertLevels, dimid_nVertLevelsP1, dimid_time, dimid_strlen
    integer :: vid_qv, vid_qc, vid_qr, vid_u, vid_w, vid_rho, vid_theta, vid_xtime
    character (len=64) :: valid_time

    if (command_argument_count() < 5) then
        write(0,*) 'Uso: gen_lbc_native init_completo.nc namelist.init_atmosphere native_target.nc saida_lbc.nc ''YYYY-MM-DD_HH:MM:SS'''
        write(0,*) '  ''YYYY-MM-DD_HH:MM:SS'' = tempo-alvo deste arquivo lbc especifico (xtime da saida) --'
        write(0,*) '  NAO e' // "'" // ' necessariamente igual ao config_start_time do namelist, que e'' o inicio'
        write(0,*) '  de toda a janela do lbc_run, nao o tempo deste passo (ver plano, secao Fase 7).'
        stop 1
    end if
    call get_command_argument(1, init_filename)
    call get_command_argument(2, namelist_filename)
    call get_command_argument(3, fg_filename)
    call get_command_argument(4, output_filename)
    call get_command_argument(5, valid_time)

    write(0,*) 'Lendo '''//trim(namelist_filename)//''''
    call read_init_atm_namelist(namelist_filename, cfg)
    extrap_airtemp = extrap_airtemp_code(cfg % config_extrap_airtemp)
    write(0,*) '  valid_time (este arquivo)=', trim(valid_time)

    !-----------------------------------------------------------------
    ! 1) Le malha/grade vertical nativa JA CALCULADA do init.nc completo
    !-----------------------------------------------------------------
    write(0,*) 'Lendo malha/grade vertical de '''//trim(init_filename)//''''
    stat = nf90_open(trim(init_filename), NF90_NOWRITE, ncid)

    block
        integer :: dimid
        stat = nf90_inq_dimid(ncid, 'nCells', dimid); stat = nf90_inquire_dimension(ncid, dimid, len=nCells)
        stat = nf90_inq_dimid(ncid, 'nEdges', dimid); stat = nf90_inquire_dimension(ncid, dimid, len=nEdges)
        stat = nf90_inq_dimid(ncid, 'maxEdges', dimid); stat = nf90_inquire_dimension(ncid, dimid, len=maxEdges)
        stat = nf90_inq_dimid(ncid, 'nVertLevels', dimid); stat = nf90_inquire_dimension(ncid, dimid, len=nVertLevels)
    end block
    write(0,*) '  nCells=', nCells, ' nEdges=', nEdges, ' maxEdges=', maxEdges, ' nVertLevels=', nVertLevels

    allocate(cellsOnEdge(2,nEdges), edgesOnCell(maxEdges,nCells), nEdgesOnCell(nCells))
    allocate(dvEdge(nEdges), dcEdge(nEdges), angleEdge(nEdges))
    allocate(zgrid(nVertLevels+1,nCells), zz(nVertLevels,nCells))
    ! compute_hydrostatic_balance espera zb/zb3 dimensionados por "nz"
    ! (=nVertLevels+1, o mesmo "nz" passado na chamada abaixo) mesmo so'
    ! usando ate' nVertLevels -- alocar do tamanho errado (nVertLevels)
    ! aqui já causou um bug real (achado 2026-09-09): o array ficava 1
    ! elemento menor por coluna do que o dummy argument declarado,
    ! corrompendo silenciosamente o acesso a zb(:,2,:)/zb3(:,2,:) (sem
    ! erro de compilacao/runtime, Fortran nao checa limites por default)
    ! -- so' afetava "w" (unico campo de saida que usa zb/zb3), o que
    ! confundiu o diagnostico a principio.
    allocate(zb(nVertLevels+1,2,nEdges), zb3(nVertLevels+1,2,nEdges))
    zb = 0.0_RKIND
    zb3 = 0.0_RKIND
    allocate(fzm(nVertLevels), fzp(nVertLevels), dzu(nVertLevels), rdzw(nVertLevels))

    call get2i(ncid, 'cellsOnEdge', 2, nEdges, cellsOnEdge)
    call get2i(ncid, 'edgesOnCell', maxEdges, nCells, edgesOnCell)
    call get1i(ncid, 'nEdgesOnCell', nCells, nEdgesOnCell)
    call get1d(ncid, 'dvEdge', nEdges, dvEdge)
    call get1d(ncid, 'dcEdge', nEdges, dcEdge)
    call get1d(ncid, 'angleEdge', nEdges, angleEdge)
    call get2d(ncid, 'zgrid', nVertLevels+1, nCells, zgrid)
    call get2d(ncid, 'zz', nVertLevels, nCells, zz)
    call get1d(ncid, 'fzm', nVertLevels, fzm)
    call get1d(ncid, 'fzp', nVertLevels, fzp)
    call get1d(ncid, 'dzu', nVertLevels, dzu)
    call get1d(ncid, 'rdzw', nVertLevels, rdzw)
    ! Arquivo so' tem nVertLevels niveis armazenados (nao nVertLevels+1 --
    ! ver nota em gen_init_native.F90 sobre so' escrever 1:nVertLevels) --
    ! le num buffer do tamanho certo e copia pro array (ja zerado) que
    ! compute_hydrostatic_balance espera.
    block
        real (kind=RKIND), dimension(:,:,:), allocatable :: zb_raw, zb3_raw
        allocate(zb_raw(nVertLevels,2,nEdges), zb3_raw(nVertLevels,2,nEdges))
        stat = nf90_inq_varid(ncid, 'zb', varid);  stat = nf90_get_var(ncid, varid, zb_raw)
        stat = nf90_inq_varid(ncid, 'zb3', varid); stat = nf90_get_var(ncid, varid, zb3_raw)
        zb(1:nVertLevels,:,:) = zb_raw
        zb3(1:nVertLevels,:,:) = zb3_raw
        deallocate(zb_raw, zb3_raw)
    end block
    stat = nf90_close(ncid)

    !-----------------------------------------------------------------
    ! 2) Fase 1 (ja rodada): le native_target.nc deste tempo
    !-----------------------------------------------------------------
    write(0,*) 'Lendo first-guess ja remapeado (Fase 1) de '''//trim(fg_filename)//''''
    allocate(fg_tt(N_PLEVELS,nCells), fg_uu(N_PLEVELS,nCells), fg_vv(N_PLEVELS,nCells))
    allocate(fg_ght(N_PLEVELS,nCells), fg_spechumd(N_PLEVELS,nCells), fg_rh(N_PLEVELS,nCells))
    allocate(fg_tt_sfc(nCells), fg_rh_sfc(nCells))

    stat = nf90_open(trim(fg_filename), NF90_NOWRITE, ncid_fg)
    call read3d(ncid_fg, 'TT',       N_PLEVELS, nCells, fg_tt)
    call read3d(ncid_fg, 'UU',       N_PLEVELS, nCells, fg_uu)
    call read3d(ncid_fg, 'VV',       N_PLEVELS, nCells, fg_vv)
    call read3d(ncid_fg, 'GHT',      N_PLEVELS, nCells, fg_ght)
    call read3d(ncid_fg, 'SPECHUMD', N_PLEVELS, nCells, fg_spechumd)
    call read3d(ncid_fg, 'RH',       N_PLEVELS, nCells, fg_rh)
    call read2d(ncid_fg, 'TT_SFC', nCells, fg_tt_sfc)
    call read2d(ncid_fg, 'RH_SFC', nCells, fg_rh_sfc)
    stat = nf90_close(ncid_fg)

    !-----------------------------------------------------------------
    ! 3) Fase 3: interpolacao vertical pro zgrid nativo (identico ao
    !    bloco de gen_init_native.F90)
    !-----------------------------------------------------------------
    write(0,*) 'Fase 3: interpolacao vertical'
    allocate(t_out(nVertLevels,nCells), relhum_out(nVertLevels,nCells))
    allocate(spechum_out(nVertLevels,nCells), pressure_out(nVertLevels,nCells))
    allocate(u_out(nVertLevels,nEdges), psfc_out(nCells), target_z_mid(nVertLevels))

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
    ! 4) Fase 4: balanco hidrostatico (identico ao bloco de
    !    gen_init_native.F90; qc/qr sempre zero, mesma justificativa)
    !-----------------------------------------------------------------
    write(0,*) 'Fase 4: balanco hidrostatico'
    allocate(qv(nVertLevels,nCells))
    if (cfg % config_use_spechumd) then
        qv = spechum_out / (1.0_RKIND - spechum_out)
    else
        write(0,*) 'Error: config_use_spechumd=false nao implementado (qv via RH/rslf)'
        stop 6
    end if

    call convert_relhum_wrt_ice(nVertLevels, nCells, t_out, relhum_out)

    allocate(rho(nVertLevels,nCells), theta(nVertLevels,nCells))
    allocate(rho_base(nVertLevels,nCells), theta_base(nVertLevels,nCells))
    allocate(w(nVertLevels+1,nCells), ru(nVertLevels,nEdges))
    allocate(precipw(nCells), surface_pressure(nCells))
    allocate(qc(nVertLevels,nCells), qr(nVertLevels,nCells))
    qc = 0.0_RKIND; qr = 0.0_RKIND

    call compute_hydrostatic_balance(nCells, nEdges, maxEdges, nVertLevels, nVertLevels+1, &
                                      nEdgesOnCell, edgesOnCell, cellsOnEdge, &
                                      zgrid, zz, zb, zb3, fzm, fzp, dzu, rdzw, &
                                      cfg % config_theta_adv_order, cfg % config_coef_3rd_order, &
                                      pressure_out, t_out, qv, u_out, &
                                      rho, theta, rho_base, theta_base, precipw, w, ru, surface_pressure)

    !-----------------------------------------------------------------
    ! 5) Escreve saida (schema lbc.*.nc real -- 7 campos com prefixo lbc_)
    !-----------------------------------------------------------------
    write(0,*) 'Escrevendo '''//trim(output_filename)//''''
    stat = nf90_create(output_filename, NF90_CLOBBER, ncid)
    stat = nf90_def_dim(ncid, 'nCells', nCells, dimid_nCells)
    stat = nf90_def_dim(ncid, 'nEdges', nEdges, dimid_nEdges)
    stat = nf90_def_dim(ncid, 'nVertLevels', nVertLevels, dimid_nVertLevels)
    stat = nf90_def_dim(ncid, 'nVertLevelsP1', nVertLevels+1, dimid_nVertLevelsP1)
    stat = nf90_def_dim(ncid, 'Time', NF90_UNLIMITED, dimid_time)
    stat = nf90_def_dim(ncid, 'StrLen', 64, dimid_strlen)

    ! Convencao ja estabelecida no resto do projeto (ex. zgrid em
    ! gen_init_native.F90): array Fortran (nVertLevels,nCells) + dimids
    ! (dimid_nVertLevels,dimid_nCells) na ordem Fortran -> arquivo acaba
    ! com a ordem C/python (nCells,nVertLevels), igual ao lbc.*.nc real.
    stat = nf90_def_var(ncid, 'lbc_qv',    NF90_DOUBLE, (/dimid_nVertLevels,   dimid_nCells, dimid_time/), vid_qv)
    stat = nf90_def_var(ncid, 'lbc_qc',    NF90_DOUBLE, (/dimid_nVertLevels,   dimid_nCells, dimid_time/), vid_qc)
    stat = nf90_def_var(ncid, 'lbc_qr',    NF90_DOUBLE, (/dimid_nVertLevels,   dimid_nCells, dimid_time/), vid_qr)
    stat = nf90_def_var(ncid, 'lbc_u',     NF90_DOUBLE, (/dimid_nVertLevels,   dimid_nEdges, dimid_time/), vid_u)
    stat = nf90_def_var(ncid, 'lbc_w',     NF90_DOUBLE, (/dimid_nVertLevelsP1, dimid_nCells, dimid_time/), vid_w)
    stat = nf90_def_var(ncid, 'lbc_rho',   NF90_DOUBLE, (/dimid_nVertLevels,   dimid_nCells, dimid_time/), vid_rho)
    stat = nf90_def_var(ncid, 'lbc_theta', NF90_DOUBLE, (/dimid_nVertLevels,   dimid_nCells, dimid_time/), vid_theta)
    stat = nf90_def_var(ncid, 'xtime', NF90_CHAR, (/dimid_strlen, dimid_time/), vid_xtime)
    stat = nf90_enddef(ncid)

    stat = nf90_put_var(ncid, vid_qv,    qv,    start=(/1,1,1/), count=(/nVertLevels,nCells,1/))
    stat = nf90_put_var(ncid, vid_qc,    qc,    start=(/1,1,1/), count=(/nVertLevels,nCells,1/))
    stat = nf90_put_var(ncid, vid_qr,    qr,    start=(/1,1,1/), count=(/nVertLevels,nCells,1/))
    stat = nf90_put_var(ncid, vid_u,     u_out, start=(/1,1,1/), count=(/nVertLevels,nEdges,1/))
    stat = nf90_put_var(ncid, vid_w,     w,     start=(/1,1,1/), count=(/nVertLevels+1,nCells,1/))
    stat = nf90_put_var(ncid, vid_rho,   rho,   start=(/1,1,1/), count=(/nVertLevels,nCells,1/))
    stat = nf90_put_var(ncid, vid_theta, theta, start=(/1,1,1/), count=(/nVertLevels,nCells,1/))
    stat = nf90_put_var(ncid, vid_xtime, trim(valid_time)//'.0000', start=(/1,1/), count=(/64,1/))

    stat = nf90_close(ncid)
    write(0,*) 'Pronto.'

    contains

    subroutine read3d(nc_id, name, n1, n2, arr)
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

    subroutine get1d(nc_id, name, n1, arr)
        integer, intent(in) :: nc_id, n1
        character(len=*), intent(in) :: name
        real (kind=RKIND), dimension(n1), intent(out) :: arr
        integer :: vid, ist
        ist = nf90_inq_varid(nc_id, name, vid)
        ist = nf90_get_var(nc_id, vid, arr)
    end subroutine get1d

    subroutine get1i(nc_id, name, n1, arr)
        integer, intent(in) :: nc_id, n1
        character(len=*), intent(in) :: name
        integer, dimension(n1), intent(out) :: arr
        integer :: vid, ist
        ist = nf90_inq_varid(nc_id, name, vid)
        ist = nf90_get_var(nc_id, vid, arr)
    end subroutine get1i

    subroutine get2d(nc_id, name, n1, n2, arr)
        integer, intent(in) :: nc_id, n1, n2
        character(len=*), intent(in) :: name
        real (kind=RKIND), dimension(n1,n2), intent(out) :: arr
        integer :: vid, ist
        ist = nf90_inq_varid(nc_id, name, vid)
        ist = nf90_get_var(nc_id, vid, arr)
    end subroutine get2d

    subroutine get2i(nc_id, name, n1, n2, arr)
        integer, intent(in) :: nc_id, n1, n2
        character(len=*), intent(in) :: name
        integer, dimension(n1,n2), intent(out) :: arr
        integer :: vid, ist
        ist = nf90_inq_varid(nc_id, name, vid)
        ist = nf90_get_var(nc_id, vid, arr)
    end subroutine get2i

end program gen_lbc_native
