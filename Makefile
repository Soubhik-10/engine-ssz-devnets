ENCLAVE_NAME := engine-ssz
ENCLAVE ?= $(ENCLAVE_NAME)
LOG_LINES ?= 6000
INCLUDE_ALL ?= 0
ETHEREUM_PACKAGE := github.com/ethpandaops/ethereum-package
CONFIG_FILE := kurtosis.config
KURTOSIS ?= kurtosis
BASH ?= bash

RETH_REPO ?= https://github.com/paradigmxyz/reth-oss.git
RETH_REF ?= ssz-engine-api-test
PRYSM_REPO ?= https://github.com/syjn99/prysm.git
PRYSM_REF ?= prototype/ssz-over-http
ERIGON_REPO ?= https://github.com/erigontech/erigon.git
ERIGON_REF ?= yperbasis/engine-ssz-793

export RETH_REPO RETH_REF PRYSM_REPO PRYSM_REF ERIGON_REPO ERIGON_REF

.PHONY: run
run:
	$(KURTOSIS) run $(ETHEREUM_PACKAGE) --enclave $(ENCLAVE_NAME) --args-file ./$(CONFIG_FILE).local.yaml --image-download always

.PHONY: run-registry
run-registry:
	$(KURTOSIS) run $(ETHEREUM_PACKAGE) --enclave $(ENCLAVE_NAME) --args-file ./$(CONFIG_FILE).registry.yaml --image-download always

.PHONY: stop
stop:
	$(KURTOSIS) enclave rm $(ENCLAVE_NAME) -f

.PHONY: compare-engine-ssz
compare-engine-ssz:
	"$(BASH)" ./scripts/compare-engine-ssz.sh

.PHONY: logs
logs:
	ENCLAVE="$(ENCLAVE)" KURTOSIS="$(KURTOSIS)" LOG_LINES="$(LOG_LINES)" INCLUDE_ALL="$(INCLUDE_ALL)" "$(BASH)" ./scripts/collect-logs.sh

.PHONY: make-logs-all
make-logs-all:
	ENCLAVE="$(ENCLAVE)" KURTOSIS="$(KURTOSIS)" LOG_LINES="$(LOG_LINES)" INCLUDE_ALL="1" "$(BASH)" ./scripts/collect-logs.sh

.PHONY: download-docker-sources
download-docker-sources:
	"$(BASH)" ./scripts/download-docker-sources.sh

.PHONY: build-docker-images
build-docker-images:
	"$(BASH)" ./scripts/build-docker-images.sh

.PHONY: make-build-docker
make-build-docker:
	"$(BASH)" ./scripts/download-docker-sources.sh
	"$(BASH)" ./scripts/build-docker-images.sh
