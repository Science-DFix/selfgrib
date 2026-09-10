.PHONY: all vendor src clean

all: vendor src

vendor:
	$(MAKE) -C vendor/convert_mpas FC=gfortran

src: vendor
	$(MAKE) -C src

clean:
	$(MAKE) -C vendor/convert_mpas clean
	$(MAKE) -C src clean
