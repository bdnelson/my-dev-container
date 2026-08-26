SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

IMAGE       ?= my-dev-container
VERSION     ?= dev
PLATFORMS   ?= linux/amd64,linux/arm64
VCS_REF     := $(shell jj log -r @ --no-graph -T 'commit_id.short()' 2>/dev/null || git rev-parse --short HEAD 2>/dev/null || echo unknown)
BUILD_DATE  := $(shell date -u +%Y-%m-%dT%H:%M:%SZ)

BUILD_ARGS = \
	--build-arg VERSION=$(VERSION) \
	--build-arg VCS_REF=$(VCS_REF) \
	--build-arg BUILD_DATE=$(BUILD_DATE)

# Root CAs handed to the container at run time rather than baked into the image.
# Mounted only when the directory exists, so this is a no-op off the corporate
# network. See certs/README.md.
CA_CERT_DIR   ?= $(HOME)/.config/ca-certificates
CA_CERT_MOUNT  = $(if $(wildcard $(CA_CERT_DIR)),-v "$(CA_CERT_DIR):/run/secrets/ca-certificates:ro")

.PHONY: help
help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'

## --- build ----------------------------------------------------------------

.PHONY: build
build: ## Build for the local architecture and load into the local daemon
	docker buildx build --load $(BUILD_ARGS) -t $(IMAGE):$(VERSION) .

.PHONY: build-all
build-all: ## Build both architectures (does not load; buildx cannot load multi-arch)
	docker buildx build --platform $(PLATFORMS) $(BUILD_ARGS) -t $(IMAGE):$(VERSION) .

.PHONY: push
push: ## Build both architectures and push to the registry
	docker buildx build --platform $(PLATFORMS) --push $(BUILD_ARGS) -t $(IMAGE):$(VERSION) .

## --- verify ---------------------------------------------------------------

.PHONY: test
test: build ## Run the smoke test against the freshly built image
	IMAGE=$(IMAGE):$(VERSION) ./bin/smoke-test.sh

.PHONY: lint
lint: ## Lint the Dockerfile and shell scripts
	@command -v hadolint >/dev/null && hadolint Dockerfile || echo "hadolint not installed, skipping"
	@command -v shellcheck >/dev/null && shellcheck bin/*.sh rootfs/usr/local/bin/* || echo "shellcheck not installed, skipping"

.PHONY: scan
scan: build ## Scan the built image for vulnerabilities
	@command -v trivy >/dev/null || { echo "trivy not installed"; exit 1; }
	trivy image --severity HIGH,CRITICAL --ignore-unfixed $(IMAGE):$(VERSION)

.PHONY: sbom
sbom: build ## Generate an SPDX SBOM for the built image
	@command -v syft >/dev/null || { echo "syft not installed"; exit 1; }
	syft $(IMAGE):$(VERSION) -o spdx-json=sbom.spdx.json
	@echo "wrote sbom.spdx.json"

## --- dependency pins ------------------------------------------------------

.PHONY: update-versions
update-versions: ## Regenerate checksums.txt from versions.env
	./bin/update-versions.sh

.PHONY: update-requirements
update-requirements: ## Regenerate the hash-pinned requirements.txt
	./bin/update-requirements.sh

.PHONY: check-upstream
check-upstream: ## Report upstream releases newer than the pins in versions.env
	./bin/check-upstream.sh

## --- use ------------------------------------------------------------------

.PHONY: shell
shell: build ## Start a throwaway shell in the image, with the repo at /work
	docker run --rm -it \
		--cap-add=NET_RAW --cap-add=NET_ADMIN \
		$(CA_CERT_MOUNT) \
		-v "$(CURDIR):/work" -w /work \
		$(IMAGE):$(VERSION) bash

.PHONY: cert-export
cert-export: ## macOS only: export the Zscaler root from the System keychain to $(CA_CERT_DIR)
	@mkdir -p "$(CA_CERT_DIR)"
	security find-certificate -a -c "Zscaler" -p /Library/Keychains/System.keychain \
		> "$(CA_CERT_DIR)/zscaler-root.crt"
	@test -s "$(CA_CERT_DIR)/zscaler-root.crt" \
		|| { echo "no Zscaler certificate found in the System keychain"; exit 1; }
	@openssl x509 -in "$(CA_CERT_DIR)/zscaler-root.crt" -noout -subject -enddate
	@echo "wrote $(CA_CERT_DIR)/zscaler-root.crt"
