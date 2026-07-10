.PHONY: build test clean

build:
	./scripts/build.sh

test:
	./tests/test-driver.sh

clean:
	rm -rf build
