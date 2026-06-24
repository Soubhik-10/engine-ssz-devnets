# Engine SSZ Devnet

Local Kurtosis devnet for comparing the Engine API v2 SSZ-over-HTTP behavior of
Reth and Erigon, both paired with a custom Prysm build.

## Components

- Reth OSS: [`paradigmxyz/reth-oss`](https://github.com/paradigmxyz/reth-oss), branch `ssz-engine-api-test`
- Prysm: [`syjn99/prysm`](https://github.com/syjn99/prysm/tree/prototype/ssz-over-http), branch `prototype/ssz-over-http`
- Erigon: [`erigontech/erigon`](https://github.com/erigontech/erigon), branch `yperbasis/engine-ssz-793`
- Ethereum package: [`ethpandaops/ethereum-package`](https://github.com/ethpandaops/ethereum-package)

The local configuration launches four Reth/Prysm pairs and four Erigon/Prysm
pairs, plus Dora, Spamoor, Prometheus, and Grafana.

## Prerequisites

- Docker Engine or Docker Desktop using Linux containers
- Kurtosis available globally as `kurtosis`
- GNU Make
- Bash
- Git
- Bazel for building the Prysm OCI images

## Build the custom images

Download all pinned client branches and build the four images used by the
devnet:

```bash
make make-build-docker
```

This produces:

```text
reth:ssz-engine-api-test
test/erigon:engine-ssz-793
prysm-bn-custom-image:engine-ssz
prysm-vc-custom-image:engine-ssz
```

The download and build phases can also be run separately:

```bash
make download-docker-sources
make build-docker-images
```

Repository URLs and refs are Make variables and can be overridden:

```bash
make make-build-docker RETH_REF=my-branch PRYSM_REF=my-branch ERIGON_REF=my-branch
```

## Run the devnet

```bash
make run
```

Inspect it with:

```bash
kurtosis enclave inspect engine-ssz
```

Remove the enclave:

```bash
make stop
```

## Collect service logs

Save the latest 6,000 lines for every EL, CL, and VC service to a separate
plain-text file named after the service. ANSI terminal color sequences are
removed automatically:

```bash
make logs
```

Logs are written to `logs/engine-ssz/<service-name>.log`. Override the enclave
or destination when needed:

```bash
make logs ENCLAVE=another-enclave LOG_DIR=logs/another
```

Set `INCLUDE_ALL=1` to include auxiliary services such as Dora and Grafana:

```bash
make make-logs-all
```

Override the per-service line limit with `LOG_LINES`:

```bash
make logs LOG_LINES=10000
```

## Compare Reth and Erigon

Run the Engine API comparison harness:

```bash
make compare-engine-ssz
```

The script discovers the live Engine API ports, downloads the shared JWT secret
from the Reth container, generates fresh bearer tokens, prints JSON identity and
capability responses, and compares binary SSZ responses. It detects the current
epoch and skips routes for forks that have not activated.

Results are written to `engine-ssz-comparison/` and ignored by Git. Requests
that need captured payload or forkchoice objects use optional fixtures described
in [`engine-ssz-fixtures/README.md`](engine-ssz-fixtures/README.md).

Useful overrides:

```bash
RETH_SERVICE=el-2-reth-prysm \
ERIGON_SERVICE=el-6-erigon-prysm \
CURRENT_EPOCH=8 \
make compare-engine-ssz
```

## Configuration

The network topology and fork schedule are defined in
[`kurtosis.config.local.yaml`](kurtosis.config.local.yaml). The comparison
script uses the same fork epochs and slot duration as this configuration.
