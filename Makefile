# VERSION defines the project version for the bundle.
# Update this value when you upgrade the version of your project.
# To re-generate a bundle for another specific version without changing the standard setup, you can:
# - use the VERSION as arg of the bundle target (e.g make bundle VERSION=0.0.2)
# - use environment variables to overwrite this value (e.g export VERSION=0.0.2)
VERSION ?= $(shell git describe --tags)

CONTAINER_CMD ?= docker

# GNU vs BSD in-place sed
ifeq ($(shell sed --version 2>/dev/null | grep -q GNU && echo gnu),gnu)
	SED_I := sed -i
else
	SED_I := sed -i ''
endif

# CHANNELS define the bundle channels used in the bundle.
# Add a new line here if you would like to change its default config. (E.g CHANNELS = "candidate,fast,stable")
# To re-generate a bundle for other specific channels without changing the standard setup, you can:
# - use the CHANNELS as arg of the bundle target (e.g make bundle CHANNELS=candidate,fast,stable)
# - use environment variables to overwrite this value (e.g export CHANNELS="candidate,fast,stable")
ifneq ($(origin CHANNELS), undefined)
BUNDLE_CHANNELS := --channels=$(CHANNELS)
endif

# DEFAULT_CHANNEL defines the default channel used in the bundle.
# Add a new line here if you would like to change its default config. (E.g DEFAULT_CHANNEL = "stable")
# To re-generate a bundle for any other default channel without changing the default setup, you can:
# - use the DEFAULT_CHANNEL as arg of the bundle target (e.g make bundle DEFAULT_CHANNEL=stable)
# - use environment variables to overwrite this value (e.g export DEFAULT_CHANNEL="stable")
ifneq ($(origin DEFAULT_CHANNEL), undefined)
BUNDLE_DEFAULT_CHANNEL := --default-channel=$(DEFAULT_CHANNEL)
endif
BUNDLE_METADATA_OPTS ?= $(BUNDLE_CHANNELS) $(BUNDLE_DEFAULT_CHANNEL)

# IMAGE_TAG_BASE defines the docker.io namespace and part of the image name for remote images.
# This variable is used to construct full image tags for bundle and catalog images.
#
# For example, running 'make bundle-build bundle-push catalog-build catalog-push' will build and push both
# ansible.com/awx-operator-bundle:$VERSION and ansible.com/awx-operator-catalog:$VERSION.
IMAGE_TAG_BASE ?= quay.io/ansible/awx-operator

# BUNDLE_IMG defines the image:tag used for the bundle.
# You can use it as an arg. (E.g make bundle-build BUNDLE_IMG=<some-registry>/<project-name-bundle>:<tag>)
BUNDLE_IMG ?= $(IMAGE_TAG_BASE)-bundle:v$(VERSION)

# BUNDLE_GEN_FLAGS are the flags passed to the operator-sdk generate bundle command
BUNDLE_GEN_FLAGS ?= -q --overwrite --version $(VERSION) $(BUNDLE_METADATA_OPTS)

# USE_IMAGE_DIGESTS defines if images are resolved via tags or digests
# You can enable this value if you would like to use SHA Based Digests
# To enable set flag to true
USE_IMAGE_DIGESTS ?= false
ifeq ($(USE_IMAGE_DIGESTS), true)
       BUNDLE_GEN_FLAGS += --use-image-digests
endif

# Image URL to use all building/pushing image targets
IMG ?= $(IMAGE_TAG_BASE):$(VERSION)
NAMESPACE ?= awx

# Helm variables
CHART_NAME ?= awx-operator
CHART_DESCRIPTION ?= A Helm chart for the AWX Operator
CHART_OWNER ?= $(GH_REPO_OWNER)
CHART_REPO ?= awx-operator
CHART_BRANCH ?= gh-pages
CHART_INDEX ?= index.yaml

# Development
KIND_CMD ?= $(shell which kind)

.PHONY: all
all: docker-build

##@ General

# The help target prints out all targets with their descriptions organized
# beneath their categories. The categories are represented by '##@' and the
# target descriptions by '##'. The awk commands is responsible for reading the
# entire set of makefiles included in this invocation, looking for lines of the
# file as xyz: ## something, and then pretty-format the target and help. Then,
# if there's a line with ##@ something, that gets pretty-printed as a category.
# More info on the usage of ANSI control characters for terminal formatting:
# https://en.wikipedia.org/wiki/ANSI_escape_code#SGR_parameters
# More info on the awk command:
# http://linuxcommand.org/lc3_adv_awk.php

.PHONY: help
help: ## Display this help.
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

##@ Development
.PHONY: kind-load
kind-load: docker-build ## Load the built image into Kind for local testing
	$(KIND_CMD) load docker-image ${IMG}

##@ Build

.PHONY: run
run: ansible-operator ## Run against the configured Kubernetes cluster in ~/.kube/config
	ANSIBLE_ROLES_PATH="$(ANSIBLE_ROLES_PATH):$(shell pwd)/roles" $(ANSIBLE_OPERATOR) run

.PHONY: docker-build
docker-build: ## Build docker image with the manager.
	${CONTAINER_CMD} build $(BUILD_ARGS) -t ${IMG} .

.PHONY: docker-push
docker-push: ## Push docker image with the manager.
	${CONTAINER_CMD} push ${IMG}

##@ Deployment

.PHONY: install
install: kustomize ## Install CRDs into the K8s cluster specified in ~/.kube/config.
	$(KUSTOMIZE) build config/crd | kubectl apply -f -

.PHONY: uninstall
uninstall: kustomize ## Uninstall CRDs from the K8s cluster specified in ~/.kube/config.
	$(KUSTOMIZE) build config/crd | kubectl delete -f -

.PHONY: gen-resources
gen-resources: kustomize ## Generate resources for controller and print to stdout
	@cd config/manager && $(KUSTOMIZE) edit set image controller=${IMG}
	@cd config/default && $(KUSTOMIZE) edit set namespace ${NAMESPACE}
	@$(KUSTOMIZE) build config/default

.PHONY: deploy
deploy: kustomize ## Deploy controller to the K8s cluster specified in ~/.kube/config.
	@cd config/manager && $(KUSTOMIZE) edit set image controller=${IMG}
	@cd config/default && $(KUSTOMIZE) edit set namespace ${NAMESPACE}
	@$(KUSTOMIZE) build config/default | kubectl apply -f -

.PHONY: undeploy
undeploy: ## Undeploy controller from the K8s cluster specified in ~/.kube/config.
	@cd config/default && $(KUSTOMIZE) edit set namespace ${NAMESPACE}
	$(KUSTOMIZE) build config/default | kubectl delete -f -

OS := $(shell uname -s | tr '[:upper:]' '[:lower:]')
ARCHA := $(shell uname -m | sed -e 's/x86_64/amd64/' -e 's/aarch64/arm64/')
ARCHX := $(shell uname -m | sed -e 's/amd64/x86_64/' -e 's/aarch64/arm64/')

.PHONY: kustomize
KUSTOMIZE = $(shell pwd)/bin/kustomize
kustomize: ## Download kustomize locally if necessary.
ifeq (,$(wildcard $(KUSTOMIZE)))
ifeq (,$(shell which kustomize 2>/dev/null))
	@{ \
	set -e ;\
	mkdir -p $(dir $(KUSTOMIZE)) ;\
	curl -sSLo - https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize/v4.5.5/kustomize_v4.5.5_$(OS)_$(ARCHA).tar.gz | \
	tar xzf - -C bin/ ;\
	}
else
KUSTOMIZE = $(shell which kustomize)
endif
endif

.PHONY: ansible-operator
ANSIBLE_OPERATOR = $(shell pwd)/bin/ansible-operator
ansible-operator: ## Download ansible-operator locally if necessary, preferring the $(pwd)/bin path over global if both exist.
ifeq (,$(wildcard $(ANSIBLE_OPERATOR)))
ifeq (,$(shell which ansible-operator 2>/dev/null))
	@{ \
	set -e ;\
	mkdir -p $(dir $(ANSIBLE_OPERATOR)) ;\
	curl -sSLo $(ANSIBLE_OPERATOR) https://github.com/operator-framework/operator-sdk/releases/download/v1.23.0/ansible-operator_$(OS)_$(ARCHA) ;\
	chmod +x $(ANSIBLE_OPERATOR) ;\
	}
else
ANSIBLE_OPERATOR = $(shell which ansible-operator)
endif
endif

.PHONY: bundle
bundle: kustomize ## Generate bundle manifests and metadata, then validate generated files.
	operator-sdk generate kustomize manifests -q
	cd config/manager && $(KUSTOMIZE) edit set image controller=$(IMG)
	$(KUSTOMIZE) build config/manifests | operator-sdk generate bundle -q --overwrite --version $(VERSION) $(BUNDLE_METADATA_OPTS)
	operator-sdk bundle validate ./bundle

.PHONY: bundle-build
bundle-build: ## Build the bundle image.
	${CONTAINER_CMD} build -f bundle.Dockerfile -t $(BUNDLE_IMG) .

.PHONY: bundle-push
bundle-push: ## Push the bundle image.
	$(MAKE) docker-push IMG=$(BUNDLE_IMG)

.PHONY: opm
OPM = ./bin/opm
opm: ## Download opm locally if necessary.
ifeq (,$(wildcard $(OPM)))
ifeq (,$(shell which opm 2>/dev/null))
	@{ \
	set -e ;\
	mkdir -p $(dir $(OPM)) ;\
	curl -sSLo $(OPM) https://github.com/operator-framework/operator-registry/releases/download/v1.23.0/$(OS)-$(ARCHA)-opm ;\
	chmod +x $(OPM) ;\
	}
else
OPM = $(shell which opm)
endif
endif

# A comma-separated list of bundle images (e.g. make catalog-build BUNDLE_IMGS=example.com/operator-bundle:v0.1.0,example.com/operator-bundle:v0.2.0).
# These images MUST exist in a registry and be pull-able.
BUNDLE_IMGS ?= $(BUNDLE_IMG)

# The image tag given to the resulting catalog image (e.g. make catalog-build CATALOG_IMG=example.com/operator-catalog:v0.2.0).
CATALOG_IMG ?= $(IMAGE_TAG_BASE)-catalog:v$(VERSION)

# Set CATALOG_BASE_IMG to an existing catalog image tag to add $BUNDLE_IMGS to that image.
ifneq ($(origin CATALOG_BASE_IMG), undefined)
FROM_INDEX_OPT := --from-index $(CATALOG_BASE_IMG)
endif

# Build a catalog image by adding bundle images to an empty catalog using the operator package manager tool, 'opm'.
# This recipe invokes 'opm' in 'semver' bundle add mode. For more information on add modes, see:
# https://github.com/operator-framework/community-operators/blob/7f1438c/docs/packaging-operator.md#updating-your-existing-operator
.PHONY: catalog-build
catalog-build: opm ## Build a catalog image.
	$(OPM) index add --container-tool ${CONTAINER_CMD} --mode semver --tag $(CATALOG_IMG) --bundles $(BUNDLE_IMGS) $(FROM_INDEX_OPT)

# Push the catalog image.
.PHONY: catalog-push
catalog-push: ## Push a catalog image.
	$(MAKE) docker-push IMG=$(CATALOG_IMG)

.PHONY: kubectl-slice
KUBECTL_SLICE = $(shell pwd)/bin/kubectl-slice
kubectl-slice: ## Download kubectl-slice locally if necessary.
ifeq (,$(wildcard $(KUBECTL_SLICE)))
ifeq (,$(shell which kubectl-slice 2>/dev/null))
	@{ \
	set -e ;\
	mkdir -p $(dir $(KUBECTL_SLICE)) ;\
	curl -sSLo - https://github.com/patrickdappollonio/kubectl-slice/releases/download/v1.1.0/kubectl-slice_1.1.0_$(OS)_$(ARCHX).tar.gz | \
	tar xzf - -C bin/ kubectl-slice ;\
	}
else
KUBECTL_SLICE = $(shell which kubectl-slice)
endif
endif

.PHONY: helm
HELM = $(shell pwd)/bin/helm
helm: ## Download helm locally if necessary.
ifeq (,$(wildcard $(HELM)))
ifeq (,$(shell which helm 2>/dev/null))
	@{ \
	set -e ;\
	mkdir -p $(dir $(HELM)) ;\
	curl -sSLo - https://get.helm.sh/helm-v3.8.0-$(OS)-$(ARCHA).tar.gz | \
	tar xzf - -C bin/ $(OS)-$(ARCHA)/helm ;\
	mv bin/$(OS)-$(ARCHA)/helm bin/helm ;\
	rmdir bin/$(OS)-$(ARCHA) ;\
	}
else
HELM = $(shell which helm)
endif
endif

.PHONY: yq
YQ = $(shell pwd)/bin/yq
yq: ## Download yq locally if necessary.
ifeq (,$(wildcard $(YQ)))
ifeq (,$(shell which yq 2>/dev/null))
	@{ \
	set -e ;\
	mkdir -p $(dir $(HELM)) ;\
	curl -sSLo - https://github.com/mikefarah/yq/releases/download/v4.20.2/yq_$(OS)_$(ARCHA).tar.gz | \
	tar xzf - -C bin/ ;\
	mv bin/yq_$(OS)_$(ARCHA) bin/yq ;\
	}
else
YQ = $(shell which yq)
endif
endif

PHONY: cr
CR = $(shell pwd)/bin/cr
cr: ## Download cr locally if necessary.
ifeq (,$(wildcard $(CR)))
ifeq (,$(shell which cr 2>/dev/null))
	@{ \
	set -e ;\
	mkdir -p $(dir $(CR)) ;\
	curl -sSLo - https://github.com/helm/chart-releaser/releases/download/v1.3.0/chart-releaser_1.3.0_$(OS)_$(ARCHA).tar.gz | \
	tar xzf - -C bin/ cr ;\
	}
else
CR = $(shell which cr)
endif
endif

charts:
	mkdir -p $@

.PHONY: helm-chart
helm-chart: helm-chart-generate

.PHONY: helm-chart-generate
helm-chart-generate: kustomize helm kubectl-slice yq charts
	@echo "== KUSTOMIZE: Set image and chart label =="
	cd config/manager && $(KUSTOMIZE) edit set image controller=${IMG}
	cd config/manager && $(KUSTOMIZE) edit set label helm.sh/chart:$(CHART_NAME)
	cd config/default && $(KUSTOMIZE) edit set label helm.sh/chart:$(CHART_NAME)

	@echo "== Gather Helm Chart Metadata =="
	# remove the existing chart if it exists
	rm -rf charts/$(CHART_NAME)
	# create new chart metadata in Chart.yaml
	cd charts && \
		$(HELM) create awx-operator --starter $(shell pwd)/.helm/starter ;\
		$(YQ) -i '.version = "$(VERSION)"' $(CHART_NAME)/Chart.yaml ;\
		$(YQ) -i '.appVersion = "$(VERSION)" | .appVersion style="double"' $(CHART_NAME)/Chart.yaml ;\
		$(YQ) -i '.description = "$(CHART_DESCRIPTION)"' $(CHART_NAME)/Chart.yaml ;\

	@echo "Generated chart metadata:"
	@cat charts/$(CHART_NAME)/Chart.yaml

	@echo "== KUSTOMIZE: Generate resources and slice into templates =="
	# place in raw-files directory so they can be modified while they are valid yaml - as soon as they are in templates/,
	# wild cards pick up the actual templates, which are not real yaml and can't have yq run on them.
	$(KUSTOMIZE) build --load-restrictor LoadRestrictionsNone config/default | \
		$(KUBECTL_SLICE) --input-file=- \
			--output-dir=charts/$(CHART_NAME)/raw-files \
			--sort-by-kind

	@echo "== GIT: Reset kustomize configs =="
	# reset kustomize configs following kustomize build
	git checkout -f config/.

	@echo "== Build Templates and CRDS =="
	# Delete metadata.namespace, release namespace will be automatically inserted by helm
	for file in charts/$(CHART_NAME)/raw-files/*; do\
		$(YQ) -i 'del(.metadata.namespace)' $${file};\
	done
	# Correct namespace for rolebinding to be release namespace, this must be explicit
	for file in charts/$(CHART_NAME)/raw-files/*rolebinding*; do\
		$(YQ) -i '.subjects[0].namespace = "{{ .Release.Namespace }}"' $${file};\
	done
	# move all custom resource definitions to crds folder
	mkdir charts/$(CHART_NAME)/crds
	mv charts/$(CHART_NAME)/raw-files/customresourcedefinition*.yaml charts/$(CHART_NAME)/crds/.
	# remove any namespace definitions
	rm -f charts/$(CHART_NAME)/raw-files/namespace*.yaml
	# move remaining resources to helm templates
	mv charts/$(CHART_NAME)/raw-files/* charts/$(CHART_NAME)/templates/.
	# remove the raw-files folder
	rm -rf charts/$(CHART_NAME)/raw-files

	# create and populate NOTES.txt
	@echo "AWX Operator installed with Helm Chart version $(VERSION)" > charts/$(CHART_NAME)/templates/NOTES.txt

	@echo "Helm chart successfully configured for $(CHART_NAME) version $(VERSION)"


.PHONY: helm-package
helm-package: cr helm-chart
	@echo "== CHART RELEASER (package) =="
	$(CR) package ./charts/awx-operator

# List all tags oldest to newest.
TAGS := $(shell git ls-remote --tags --sort=version:refname --refs -q | cut -d/ -f3)

# The actual release happens in ansible/helm-release.yml
# until https://github.com/helm/chart-releaser/issues/122 happens
.PHONY: helm-index
helm-index: cr helm-chart
	@echo "== CHART RELEASER (httpsorigin) =="
	git remote add httpsorigin "https://github.com/$(CHART_OWNER)/$(CHART_REPO).git"
	git fetch httpsorigin

	# This step to workaround issues with old releases being dropped.
	# Until https://github.com/helm/chart-releaser/issues/133 happens
	@echo "== CHART FETCH previous releases =="
	# Download all old releases
	cd .cr-release-packages;\
	for tag in $(TAGS); do\
		dl_url="https://github.com/$${CHART_OWNER}/$${CHART_REPO}/releases/download/$${tag}/$${CHART_REPO}-$${tag}.tgz";\
		curl -RLOs -z "$${CHART_REPO}-$${tag}.tgz" --fail $${dl_url};\
		result=$$?;\
		if [ $${result} -eq 0 ]; then\
			echo "Downloaded $$dl_url";\
		fi;\
	done

	@echo "== CHART RELEASER (index) =="
	$(CR) index \
		--owner "$(CHART_OWNER)" \
		--git-repo "$(CHART_REPO)" \
		--token "$(CR_TOKEN)" \
		--pages-branch "$(CHART_BRANCH)" \
		--index-path "./charts/$(CHART_INDEX)" \
		--charts-repo "https://$(CHART_OWNER).github.io/$(CHART_REPO)/$(CHART_INDEX)" \
		--remote httpsorigin \
		--release-name-template="{{ .Version }}" \
		--push
