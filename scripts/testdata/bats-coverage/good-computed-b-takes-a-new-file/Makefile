.PHONY: check a b
A_BATS := t/x.bats
NAMED := $(shell grep -ho 't/[A-Za-z0-9._-]*\.bats' $(firstword $(MAKEFILE_LIST)) | sort -u)
B_BATS := $(filter-out $(NAMED),$(sort $(wildcard t/*.bats)))
check: a b
a:
	@bats $(A_BATS)
b:
	@bats $(B_BATS)
