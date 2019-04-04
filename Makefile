#This makefile is used by ci-operator

CGO_ENABLED=0
GOOS=linux
CORE_IMAGES=./cmd/broker/ingress/ ./cmd/broker/filter/ ./cmd/controller/ ./cmd/fanoutsidecar/ ./cmd/pong/ ./cmd/sendevent/ ./cmd/webhook/
TEST_IMAGES=$(shell find ./test/test_images -mindepth 1 -maxdepth 1 -type d)

install:
	go install $(CORE_IMAGES)
	go build -o $(GOPATH)/bin/in-memory-channel-controller ./pkg/provisioners/inmemory/controller
	go build -o $(GOPATH)/bin/kafka-channel-controller ./contrib/kafka/cmd/controller
	go build -o $(GOPATH)/bin/kafka-channel-dispatcher ./contrib/kafka/cmd/dispatcher
.PHONY: install

test-install:
	for img in $(TEST_IMAGES); do \
		go install $$img ; \
	done
.PHONY: test-install

test-e2e:
	sh openshift/e2e-tests-openshift.sh
.PHONY: test-e2e

# Generate Dockerfiles used by ci-operator. The files need to be committed manually.
generate-dockerfiles:
	./openshift/ci-operator/generate-dockerfiles.sh openshift/ci-operator/knative-images $(CORE_IMAGES)
	./openshift/ci-operator/generate-dockerfiles.sh openshift/ci-operator/knative-images in-memory-channel-controller
	./openshift/ci-operator/generate-dockerfiles.sh openshift/ci-operator/knative-images kafka-channel-controller
	./openshift/ci-operator/generate-dockerfiles.sh openshift/ci-operator/knative-images kafka-channel-dispatcher
	./openshift/ci-operator/generate-dockerfiles.sh openshift/ci-operator/knative-test-images $(TEST_IMAGES)
.PHONY: generate-dockerfiles