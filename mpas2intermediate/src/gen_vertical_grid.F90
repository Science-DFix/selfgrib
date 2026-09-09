program gen_vertical_grid

    ! Fase 2 do plano de interpolacao nativa Voronoi -- driver que le a
    ! conectividade + terreno de uma malha MPAS de destino (static.nc) e
    ! gera a grade vertical nativa (zgrid/zz/zxu/rdzw/dzu/rdzu/fzm/fzp/
    ! cf1/cf2/cf3/dss), usando vertical_grid.F90 (extraido do
    ! init_atm_case_gfs real, branch config_tc_vertical_grid).
    !
    ! Uso:
    !   gen_vertical_grid malha-alvo.static.nc namelist.init_atmosphere saida.nc
    !
    ! config_* lidos do namelist.init_atmosphere REAL do experimento (via
    ! namelist_config.F90) -- reproduzivel pra qualquer malha/experimento,
    ! nao so' o caso SouthAmerica usado como exemplo inicial (achado
    ! 2026-09-09: antes desta versao, os config_* ficavam fixos no
    ! codigo-fonte, exigindo recompilar pra cada malha/config diferente).
    !
    ! config_hybrid_coordinate/config_hybrid_top_z sao excecao: NAO
    ! aparecem em nenhum namelist.init_atmosphere real (nao sao opcoes de
    ! namelist na versao 3.0.2 do MPAS-Model, sao hardcoded no proprio
    ! codigo-fonte -- ver achado na memoria project-vertical-grid-divergence),
    ! entao continuam fixos aqui tambem, fielmente.

    use mpas_kind_types, only : RKIND
    use scan_input
    use vertical_grid
    use namelist_config
    use netcdf

    implicit none

    character (len=1024) :: mesh_filename, namelist_filename, output_filename
    type (input_handle_type) :: handle
    type (input_field_type) :: field
    type (init_atm_config_type) :: cfg

    integer :: nCells, nEdges, maxEdges, nVertLevels
    logical, parameter :: config_hybrid_coordinate = .true.
    real (kind=RKIND), parameter :: config_hybrid_top_z = 30000.0_RKIND

    integer, dimension(:), allocatable :: nEdgesOnCell
    integer, dimension(:,:), allocatable :: cellsOnCell, edgesOnCell, cellsOnEdge
    real (kind=RKIND), dimension(:), allocatable :: dvEdge, dcEdge, ter

    real (kind=RKIND), dimension(:,:), allocatable :: zgrid
    real (kind=RKIND), dimension(:,:), allocatable :: zz, dss
    real (kind=RKIND), dimension(:,:), allocatable :: zxu
    real (kind=RKIND), dimension(:), allocatable :: rdzw, dzu, rdzu, fzm, fzp
    real (kind=RKIND) :: cf1, cf2, cf3

    integer :: stat, ncid, dimid_nCells, dimid_nEdges, dimid_nVertLevels, dimid_nVertLevelsP1
    integer :: varid

    if (command_argument_count() < 3) then
        write(0,*) 'Uso: gen_vertical_grid malha-alvo.static.nc namelist.init_atmosphere saida.nc'
        stop 1
    end if
    call get_command_argument(1, mesh_filename)
    call get_command_argument(2, namelist_filename)
    call get_command_argument(3, output_filename)

    write(0,*) 'Lendo '''//trim(namelist_filename)//''''
    call read_init_atm_namelist(namelist_filename, cfg)
    nVertLevels = cfg % config_nvertlevels
    write(0,*) '  config_nvertlevels=', nVertLevels, ' config_ztop=', cfg % config_ztop, &
               ' config_nsm=', cfg % config_nsm, ' config_dzmin=', cfg % config_dzmin

    write(0,*) 'Lendo conectividade/terreno de '''//trim(mesh_filename)//''''
    if (scan_input_open(mesh_filename, handle) /= 0) then
        write(0,*) 'Error: nao consegui abrir '//trim(mesh_filename)
        stop 2
    end if

    stat = scan_input_for_field(handle, 'nEdgesOnCell', field)
    nCells = field % dimlens(1)
    stat = scan_input_read_field(field)
    allocate(nEdgesOnCell(nCells))
    nEdgesOnCell = field % array1i
    stat = scan_input_free_field(field)

    stat = scan_input_for_field(handle, 'cellsOnCell', field)
    maxEdges = field % dimlens(1)
    stat = scan_input_read_field(field)
    allocate(cellsOnCell(maxEdges,nCells))
    cellsOnCell = field % array2i
    stat = scan_input_free_field(field)

    stat = scan_input_for_field(handle, 'edgesOnCell', field)
    stat = scan_input_read_field(field)
    allocate(edgesOnCell(maxEdges,nCells))
    edgesOnCell = field % array2i
    stat = scan_input_free_field(field)

    stat = scan_input_for_field(handle, 'cellsOnEdge', field)
    nEdges = field % dimlens(2)
    stat = scan_input_read_field(field)
    allocate(cellsOnEdge(2,nEdges))
    cellsOnEdge = field % array2i
    stat = scan_input_free_field(field)

    stat = scan_input_for_field(handle, 'dvEdge', field)
    stat = scan_input_read_field(field)
    allocate(dvEdge(nEdges))
    dvEdge = real(field % array1r, RKIND)
    stat = scan_input_free_field(field)

    stat = scan_input_for_field(handle, 'dcEdge', field)
    stat = scan_input_read_field(field)
    allocate(dcEdge(nEdges))
    dcEdge = real(field % array1r, RKIND)
    stat = scan_input_free_field(field)

    stat = scan_input_for_field(handle, 'ter', field)
    stat = scan_input_read_field(field)
    allocate(ter(nCells))
    ter = real(field % array1r, RKIND)
    stat = scan_input_free_field(field)

    stat = scan_input_close(handle)

    write(0,*) '  nCells=', nCells, ' nEdges=', nEdges, ' maxEdges=', maxEdges

    allocate(zgrid(nVertLevels+1,nCells))
    allocate(zz(nVertLevels,nCells))
    allocate(dss(nVertLevels,nCells))
    allocate(zxu(nVertLevels,nEdges))
    allocate(rdzw(nVertLevels), dzu(nVertLevels), rdzu(nVertLevels), fzm(nVertLevels), fzp(nVertLevels))

    write(0,*) 'Calculando grade vertical nativa (config_tc_vertical_grid)'
    call compute_vertical_grid(nCells, nEdges, maxEdges, nVertLevels, &
                                nEdgesOnCell, cellsOnCell, edgesOnCell, cellsOnEdge, &
                                dvEdge, dcEdge, ter, &
                                cfg % config_ztop, cfg % config_nsmterrain, cfg % config_nsm, cfg % config_dzmin, &
                                config_hybrid_coordinate, config_hybrid_top_z, &
                                cfg % config_interface_projection, &
                                zgrid, zz, zxu, rdzw, dzu, rdzu, fzm, fzp, cf1, cf2, cf3, dss)

    write(0,*) 'Escrevendo '''//trim(output_filename)//''''
    stat = nf90_create(output_filename, NF90_CLOBBER, ncid)
    stat = nf90_def_dim(ncid, 'nCells', nCells, dimid_nCells)
    stat = nf90_def_dim(ncid, 'nEdges', nEdges, dimid_nEdges)
    stat = nf90_def_dim(ncid, 'nVertLevels', nVertLevels, dimid_nVertLevels)
    stat = nf90_def_dim(ncid, 'nVertLevelsP1', nVertLevels+1, dimid_nVertLevelsP1)

    stat = nf90_def_var(ncid, 'zgrid', NF90_DOUBLE, (/dimid_nVertLevelsP1, dimid_nCells/), varid)
    stat = nf90_def_var(ncid, 'zz',    NF90_DOUBLE, (/dimid_nVertLevels,   dimid_nCells/), varid)
    stat = nf90_def_var(ncid, 'dss',   NF90_DOUBLE, (/dimid_nVertLevels,   dimid_nCells/), varid)
    stat = nf90_def_var(ncid, 'zxu',   NF90_DOUBLE, (/dimid_nVertLevels,   dimid_nEdges/), varid)
    stat = nf90_def_var(ncid, 'rdzw',  NF90_DOUBLE, (/dimid_nVertLevels/), varid)
    stat = nf90_def_var(ncid, 'dzu',   NF90_DOUBLE, (/dimid_nVertLevels/), varid)
    stat = nf90_def_var(ncid, 'rdzu',  NF90_DOUBLE, (/dimid_nVertLevels/), varid)
    stat = nf90_def_var(ncid, 'fzm',   NF90_DOUBLE, (/dimid_nVertLevels/), varid)
    stat = nf90_def_var(ncid, 'fzp',   NF90_DOUBLE, (/dimid_nVertLevels/), varid)
    stat = nf90_def_var(ncid, 'cf1',   NF90_DOUBLE, varid)
    stat = nf90_def_var(ncid, 'cf2',   NF90_DOUBLE, varid)
    stat = nf90_def_var(ncid, 'cf3',   NF90_DOUBLE, varid)
    stat = nf90_enddef(ncid)

    stat = nf90_inq_varid(ncid, 'zgrid', varid); stat = nf90_put_var(ncid, varid, zgrid)
    stat = nf90_inq_varid(ncid, 'zz',    varid); stat = nf90_put_var(ncid, varid, zz)
    stat = nf90_inq_varid(ncid, 'dss',   varid); stat = nf90_put_var(ncid, varid, dss)
    stat = nf90_inq_varid(ncid, 'zxu',   varid); stat = nf90_put_var(ncid, varid, zxu)
    stat = nf90_inq_varid(ncid, 'rdzw',  varid); stat = nf90_put_var(ncid, varid, rdzw)
    stat = nf90_inq_varid(ncid, 'dzu',   varid); stat = nf90_put_var(ncid, varid, dzu)
    stat = nf90_inq_varid(ncid, 'rdzu',  varid); stat = nf90_put_var(ncid, varid, rdzu)
    stat = nf90_inq_varid(ncid, 'fzm',   varid); stat = nf90_put_var(ncid, varid, fzm)
    stat = nf90_inq_varid(ncid, 'fzp',   varid); stat = nf90_put_var(ncid, varid, fzp)
    stat = nf90_inq_varid(ncid, 'cf1',   varid); stat = nf90_put_var(ncid, varid, cf1)
    stat = nf90_inq_varid(ncid, 'cf2',   varid); stat = nf90_put_var(ncid, varid, cf2)
    stat = nf90_inq_varid(ncid, 'cf3',   varid); stat = nf90_put_var(ncid, varid, cf3)

    stat = nf90_close(ncid)

    write(0,*) 'Pronto.'

end program gen_vertical_grid
