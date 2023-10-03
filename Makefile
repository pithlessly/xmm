libxmm.so: libxmm_functions.zig libxmm_main.c
	zig build-lib \
		-dynamic \
		-fallow-shlib-undefined \
		-femit-bin=$@ \
		$$(python3-config --include) \
		$^

.PHONY: clean
clean:
	rm -f libxmm.so libxmm.so.o
