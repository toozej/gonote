# Set sane defaults for Make
SHELL = bash
.DELETE_ON_ERROR:
MAKEFLAGS += --warn-undefined-variables
MAKEFLAGS += --no-builtin-rules

# Set default goal such that `make` runs `make help`
.DEFAULT_GOAL := help

# Build info
BUILDER = $(shell whoami)@$(shell hostname)
NOW = $(shell date -u +"%Y-%m-%dT%H:%M:%SZ")

# Version control
VERSION = $(shell git describe --tags --dirty --always)
COMMIT = $(shell git rev-parse --short HEAD)
BRANCH = $(shell git rev-parse --abbrev-ref HEAD)

# Linker flags
PKG = $(shell head -n 1 go.mod | cut -c 8-)
VER = $(PKG)/version
LDFLAGS = -s -w \
	-X $(VER).Version=$(or $(VERSION),unknown) \
	-X $(VER).Commit=$(or $(COMMIT),unknown) \
	-X $(VER).Branch=$(or $(BRANCH),unknown) \
	-X $(VER).BuiltAt=$(NOW) \
	-X $(VER).Builder=$(BUILDER)
	
OS = $(shell uname -s)
ifeq ($(OS), Linux)
	OPENER=xdg-open
else
	OPENER=open
endif

DEPLOY_HOSTNAME = $(shell grep DEPLOY_HOSTNAME ./deploy.env | awk -F= '{print $$2}')
DEPLOY_APPNAME = $(subst .,,$(DEPLOY_HOSTNAME))
DEPLOY_POSTGRES_PASSWORD = $(shell grep DEPLOY_POSTGRES_PASSWORD ./deploy.env | awk -F= '{print $$2}')

.PHONY: all vet test build verify run up down distroless-build distroless-run local local-vet local-test local-cover local-run local-release-test local-release local-sign local-verify local-release-verify install deploy deploy-secrets deploy-only deploy-ip deploy-cert deploy-psql-console backup get-cosign-pub-key docker-login pre-commit-install pre-commit-run pre-commit pre-reqs docs docs-generate docs-serve clean help wiptest

wiptest: local-build
	./gonote list

all: vet pre-commit clean test build verify run ## Run default workflow via Docker
local: local-update-deps local-vendor local-vet pre-commit clean local-test local-cover local-build local-sign local-verify local-run ## Run default workflow using locally installed Golang toolchain
local-release-verify: local-release local-sign local-verify ## Release and verify using locally installed Golang toolchain
pre-reqs: pre-commit-install ## Install pre-commit hooks and necessary binaries

vet: ## Run `go vet` in Docker
	docker build --target vet -f $(CURDIR)/Dockerfile -t toozej/gonote:latest . 

test: ## Run `go test` in Docker
	docker build --target test -f $(CURDIR)/Dockerfile -t toozej/gonote:latest . 
	@echo -e "\nStatements missing coverage"
	@grep -v -e " 1$$" c.out

build: ## Build Docker image, including running tests
	docker build -f $(CURDIR)/Dockerfile -t toozej/gonote:latest .

get-cosign-pub-key: ## Get gonote Cosign public key from GitHub
	test -f $(CURDIR)/gonote.pub || curl --silent https://raw.githubusercontent.com/toozej/gonote/main/gonote.pub -O

verify: get-cosign-pub-key ## Verify Docker image with Cosign
	cosign verify --key $(CURDIR)/gonote.pub toozej/gonote:latest

run: ## Run built Docker image
	-docker kill gonote
	docker run --rm -d --name gonote -v $(CURDIR)/config:/config toozej/gonote:latest

local-update-deps: ## Run `go get -t -u ./...` to update Go module dependencies
	go get -t -u ./...

local-vet: ## Run `go vet` using locally installed golang toolchain
	go vet $(CURDIR)/...

local-vendor: ## Run `go mod vendor` using locally installed golang toolchain
	go mod vendor

local-test: ## Run `go test` using locally installed golang toolchain
	go test -coverprofile c.out -v $(CURDIR)/...
	@echo -e "\nStatements missing coverage"
	@grep -v -e " 1$$" c.out

local-cover: ## View coverage report in web browser
	go tool cover -html=c.out

local-build: ## Run `go build` using locally installed golang toolchain
	CGO_ENABLED=0 go build -ldflags="$(LDFLAGS)" $(CURDIR)/

local-run: ## Run locally built binary
	$(CURDIR)/gonote --help

local-release-test: ## Build assets and test goreleaser config using locally installed golang toolchain and goreleaser
	goreleaser check
	goreleaser build --rm-dist --snapshot

local-release: local-test docker-login ## Release assets using locally installed golang toolchain and goreleaser
	if test -e $(CURDIR)/gonote.key && test -e $(CURDIR)/cicd.env; then \
		export `cat $(CURDIR)/cicd.env | xargs` && git push origin `git describe --tags` && goreleaser release --rm-dist; \
	else \
		echo "Missing required cosign private key or environment variables. Cannot release."; \
	fi

local-sign: local-test ## Sign locally installed golang toolchain and cosign
	if test -e $(CURDIR)/gonote.key && test -e $(CURDIR)/cicd.env; then \
		export `cat $(CURDIR)/cicd.env | xargs` && cosign sign-blob --key=$(CURDIR)/gonote.key --output-signature=$(CURDIR)/gonote.sig $(CURDIR)/gonote; \
	else \
		echo "no cosign private key found at $(CURDIR)/gonote.key. Cannot release."; \
	fi

local-verify: get-cosign-pub-key ## Verify locally compiled binary
	# cosign here assumes you're using Linux AMD64 binary
	cosign verify-blob --key $(CURDIR)/gonote.pub --signature $(CURDIR)/gonote.sig $(CURDIR)/gonote

install: local-build local-verify ## Install compiled binary to local machine
	sudo cp $(CURDIR)/gonote /usr/local/bin/gonote
	sudo chmod 0755 /usr/local/bin/gonote

docker-login: ## Login to Docker registries used to publish images to
	if test -e $(CURDIR)/cicd.env; then \
		export `cat $(CURDIR)/cicd.env | xargs`; \
		echo $${DOCKERHUB_TOKEN} | docker login docker.io --username $${DOCKERHUB_USERNAME} --password-stdin; \
		echo $${QUAY_TOKEN} | docker login quay.io --username $${QUAY_USERNAME} --password-stdin; \
		echo $${GITHUB_GHCR_TOKEN} | docker login ghcr.io --username $${GITHUB_USERNAME} --password-stdin; \
	else \
		echo "No container registry credentials found, need to add them to ./cicd.env. See README.md for more info"; \
	fi

pre-commit: pre-commit-install pre-commit-run ## Install and run pre-commit hooks

pre-commit-install: ## Install pre-commit hooks and necessary binaries
	# golangci-lint
	go install github.com/golangci/golangci-lint/cmd/golangci-lint@latest
	# goimports
	go install golang.org/x/tools/cmd/goimports@latest
	# gosec
	go install github.com/securego/gosec/v2/cmd/gosec@latest
	# staticcheck
	go install honnef.co/go/tools/cmd/staticcheck@latest
	# go-critic
	go install github.com/go-critic/go-critic/cmd/gocritic@latest
	# structslop
	go install github.com/orijtech/structslop/cmd/structslop@latest
	# shellcheck
	command -v shellcheck || sudo dnf install -y ShellCheck || sudo apt install -y shellcheck
	# checkmake
	go install github.com/mrtazz/checkmake/cmd/checkmake@latest
	# goreleaser
	go install github.com/goreleaser/goreleaser@latest
	# syft
	go install github.com/anchore/syft/cmd/syft@latest
	# cosign
	go install github.com/sigstore/cosign/cmd/cosign@latest
	# go-licenses
	go install github.com/google/go-licenses@latest
	# go vuln check
	go install golang.org/x/vuln/cmd/govulncheck@latest
	# install and update pre-commits
	pre-commit install
	pre-commit autoupdate

pre-commit-run: ## Run pre-commit hooks against all files
	pre-commit run --all-files
	# manually run the following checks since their pre-commits aren't working or don't exist
	go-licenses report github.com/toozej/gonote/
	govulncheck ./...

docs: docs-generate docs-serve ## Generate and serve documentation

docs-generate:
	docker build -f $(CURDIR)/Dockerfile.docs -t toozej/gonote:docs . 
	docker run --rm --name gonote-docs -v $(CURDIR):/package -v $(CURDIR)/docs:/docs toozej/gonote:docs

docs-serve: ## Serve documentation on http://localhost:9000
	docker run -d --rm --name gonote-docs-serve -p 9000:3080 -v $(CURDIR)/docs:/data thomsch98/markserv
	$(OPENER) http://localhost:9000/docs.md
	@echo -e "to stop docs container, run:\n"
	@echo "docker kill gonote-docs-serve"

clean: ## Remove any locally compiled binaries
	rm -f $(CURDIR)/gonote

help: ## Display help text
	@grep -E '^[a-zA-Z_-]+ ?:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'
