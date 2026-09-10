FC = gfortran
NF_FFLAGS := $(shell nf-config --fflags)
NF_FLIBS  := $(shell nf-config --flibs)

# -fconvert=big-endian -frecord-marker=4: mesma convencao usada para
# compilar o WPS/ungrib e o MPAS-Model (ver WPS/configure.wps) -- necessaria
# para que os arquivos binarios intermediarios escritos por pack_intermediate
# sejam lidos corretamente por mpas_init_atm_read_met.F e por rd_intermediate.exe.
FFLAGS = -O2 -g -fbacktrace -ffree-line-length-none -fconvert=big-endian -frecord-marker=4 $(NF_FFLAGS)

SRC = .
OBJDIR = obj

COMMON_OBJS = $(OBJDIR)/mpas_kind_types.o \
              $(OBJDIR)/pressure_levels.o \
              $(OBJDIR)/interp_vertical.o \
              $(OBJDIR)/write_intermediate.o

# hinterp_native (Fase 1 da rota de interpolacao nativa Voronoi, ver
# doc_voronoi/prototipo_scatter/ e o plano de implementacao) reusa, sem
# modificar, os modulos de remapeamento baricentrico ja compilados do
# convert_mpas -- que precisa estar compilado ANTES deste Makefile rodar
# (ver ../vendor/convert_mpas/README.md, "make FC=gfortran"). Sem as flags
# -fconvert=big-endian/-frecord-marker=4 (so' fazem sentido pro binario
# WPS de write_intermediate.F90/pack_intermediate.F90): hinterp_native so'
# faz E/S via NetCDF.
CONVERT_MPAS_SRC = ../vendor/convert_mpas/src
CONVERT_MPAS_OBJS = $(CONVERT_MPAS_SRC)/copy_atts.o \
                     $(CONVERT_MPAS_SRC)/mpas_mesh.o \
                     $(CONVERT_MPAS_SRC)/target_mesh.o \
                     $(CONVERT_MPAS_SRC)/remapper.o \
                     $(CONVERT_MPAS_SRC)/file_output.o \
                     $(CONVERT_MPAS_SRC)/field_list.o \
                     $(CONVERT_MPAS_SRC)/timer.o \
                     $(CONVERT_MPAS_SRC)/scan_input.o
HINTERP_FFLAGS = -O2 -g -fbacktrace -ffree-line-length-none $(NF_FFLAGS) -I$(CONVERT_MPAS_SRC)

.PHONY: all clean

all: test_interp extract_fields pack_intermediate hinterp_native gen_vertical_grid gen_init_native gen_lbc_native

$(OBJDIR):
	mkdir -p $(OBJDIR)

$(OBJDIR)/%.o: $(SRC)/%.F90 | $(OBJDIR)
	$(FC) $(FFLAGS) -J$(OBJDIR) -I$(OBJDIR) -c $< -o $@

test_interp: $(OBJDIR)/mpas_kind_types.o $(OBJDIR)/pressure_levels.o $(OBJDIR)/interp_vertical.o $(OBJDIR)/test_interp.o
	$(FC) $(FFLAGS) -o $@ $^ $(NF_FLIBS)

extract_fields: $(OBJDIR)/mpas_kind_types.o $(OBJDIR)/pressure_levels.o $(OBJDIR)/interp_vertical.o $(OBJDIR)/extract_fields.o
	$(FC) $(FFLAGS) -o $@ $^ $(NF_FLIBS)

pack_intermediate: $(COMMON_OBJS) $(OBJDIR)/pack_intermediate.o
	$(FC) $(FFLAGS) -o $@ $^ $(NF_FLIBS)

$(OBJDIR)/hinterp_native.o: $(SRC)/hinterp_native.F90 | $(OBJDIR)
	$(FC) $(HINTERP_FFLAGS) -J$(OBJDIR) -I$(OBJDIR) -c $< -o $@

hinterp_native: $(CONVERT_MPAS_OBJS) $(OBJDIR)/hinterp_native.o
	$(FC) $(HINTERP_FFLAGS) -o $@ $^ $(NF_FLIBS)

# gen_vertical_grid (Fase 2): so' precisa do scan_input.F90 do convert_mpas
# pra leitura genérica de netCDF (nao usa remapper/target_mesh/file_output).
$(OBJDIR)/gen_vertical_grid.o: $(SRC)/gen_vertical_grid.F90 | $(OBJDIR)
	$(FC) $(FFLAGS) -I$(CONVERT_MPAS_SRC) -J$(OBJDIR) -I$(OBJDIR) -c $< -o $@

gen_vertical_grid: $(OBJDIR)/mpas_kind_types.o $(OBJDIR)/mpas_constants.o $(OBJDIR)/vertical_grid.o \
                    $(OBJDIR)/namelist_config.o \
                    $(CONVERT_MPAS_SRC)/scan_input.o $(OBJDIR)/gen_vertical_grid.o
	$(FC) $(HINTERP_FFLAGS) -o $@ $^ $(NF_FLIBS)

# Fases 3+4 (vinterp_native.F90/hydrostatic.F90) + driver gen_init_native.F90.
$(OBJDIR)/gen_init_native.o: $(SRC)/gen_init_native.F90 | $(OBJDIR)
	$(FC) $(FFLAGS) -I$(CONVERT_MPAS_SRC) -J$(OBJDIR) -I$(OBJDIR) -c $< -o $@

gen_init_native: $(OBJDIR)/mpas_kind_types.o $(OBJDIR)/mpas_constants.o $(OBJDIR)/pressure_levels.o \
                  $(OBJDIR)/vertical_grid.o $(OBJDIR)/vinterp_native.o $(OBJDIR)/hydrostatic.o \
                  $(OBJDIR)/surface_fields.o $(OBJDIR)/namelist_config.o \
                  $(CONVERT_MPAS_SRC)/scan_input.o $(OBJDIR)/gen_init_native.o
	$(FC) $(HINTERP_FFLAGS) -o $@ $^ $(NF_FLIBS)

$(OBJDIR)/gen_lbc_native.o: $(SRC)/gen_lbc_native.F90 | $(OBJDIR)
	$(FC) $(FFLAGS) -I$(CONVERT_MPAS_SRC) -J$(OBJDIR) -I$(OBJDIR) -c $< -o $@

gen_lbc_native: $(OBJDIR)/mpas_kind_types.o $(OBJDIR)/mpas_constants.o $(OBJDIR)/pressure_levels.o \
                 $(OBJDIR)/vinterp_native.o $(OBJDIR)/hydrostatic.o $(OBJDIR)/namelist_config.o \
                 $(OBJDIR)/gen_lbc_native.o
	$(FC) $(HINTERP_FFLAGS) -o $@ $^ $(NF_FLIBS)

clean:
	rm -rf $(OBJDIR) test_interp extract_fields pack_intermediate hinterp_native gen_vertical_grid gen_init_native gen_lbc_native
