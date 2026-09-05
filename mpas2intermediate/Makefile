FC = gfortran
NF_FFLAGS := $(shell nf-config --fflags)
NF_FLIBS  := $(shell nf-config --flibs)

# -fconvert=big-endian -frecord-marker=4: mesma convencao usada para
# compilar o WPS/ungrib e o MPAS-Model (ver WPS/configure.wps) -- necessaria
# para que os arquivos binarios intermediarios escritos por pack_intermediate
# sejam lidos corretamente por mpas_init_atm_read_met.F e por rd_intermediate.exe.
FFLAGS = -O2 -g -fbacktrace -ffree-line-length-none -fconvert=big-endian -frecord-marker=4 $(NF_FFLAGS)

SRC = src
OBJDIR = obj

COMMON_OBJS = $(OBJDIR)/mpas_kind_types.o \
              $(OBJDIR)/pressure_levels.o \
              $(OBJDIR)/interp_vertical.o \
              $(OBJDIR)/write_intermediate.o

.PHONY: all clean

all: test_interp extract_fields pack_intermediate

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

clean:
	rm -rf $(OBJDIR) test_interp extract_fields pack_intermediate
