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
	@command -v shellcheck >/dev/null && shellcheck bin/*.sh rootfs/usr/local/bin/devbox-help rootfs/usr/local/bin/init-docker-socket || echo "shellcheck not installed, skipping"

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
		-v "$(CURDIR):/work" -w /work \
		$(IMAGE):$(VERSION) bash
