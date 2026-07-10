.PHONY: build build-cpu test clean

build:
	./scripts/build.sh

build-cpu:
	./scripts/build-cpu.sh

test:
	./tests/test-driver.sh
	./tests/test-reference.sh

clean:
	rm -rf build
