#!/bin/sh 

source $(dirname $0)/../vendor/github.com/knative/test-infra/scripts/e2e-tests.sh

set -x

readonly BUILD_VERSION=v0.4.0
readonly SERVING_VERSION=v0.4.1
readonly EVENTING_SOURCES_VERSION=v0.4.1
readonly MAISTRA_VERSION="0.6"


readonly MAISTRA_RELEASE=https://raw.githubusercontent.com/Maistra/openshift-ansible/maistra-${MAISTRA_VERSION}/istio/istio_community_operator_template.yaml
readonly BUILD_RELEASE=https://github.com/knative/build/releases/download/${BUILD_VERSION}/build.yaml
readonly SERVING_RELEASE=https://github.com/knative/serving/releases/download/${SERVING_VERSION}/serving.yaml
readonly EVENTING_SOURCES_RELEASE=https://github.com/knative/eventing-sources/releases/download/${EVENTING_SOURCES_VERSION}/release.yaml

readonly K8S_CLUSTER_OVERRIDE=$(oc config current-context | awk -F'/' '{print $2}')
readonly API_SERVER=$(oc config view --minify | grep server | awk -F'//' '{print $2}' | awk -F':' '{print $1}')
readonly INTERNAL_REGISTRY="${INTERNAL_REGISTRY:-"docker-registry.default.svc:5000"}"
readonly USER=$KUBE_SSH_USER #satisfy e2e_flags.go#initializeFlags()
readonly OPENSHIFT_REGISTRY="${OPENSHIFT_REGISTRY:-"registry.svc.ci.openshift.org"}"
readonly INSECURE="${INSECURE:-"false"}"
readonly SERVING_NAMESPACE=knative-serving
readonly EVENTING_NAMESPACE=knative-eventing
readonly TEST_NAMESPACE=e2etest
#readonly TEST_FUNCTION_NAMESPACE=e2etestfn3
readonly TEST_FUNCTION_NAMESPACE=e2etest-knative-eventing

env

# Loops until duration (car) is exceeded or command (cdr) returns non-zero
function timeout_non_zero() {
  SECONDS=0; TIMEOUT=$1; shift
  while eval $*; do
    sleep 5
    [[ $SECONDS -gt $TIMEOUT ]] && echo "ERROR: Timed out" && return 1
  done
  return 0
}

function patch_istio_for_knative(){
  local sidecar_config=$(oc get configmap -n istio-system istio-sidecar-injector -o yaml)
  if [[ -z "${sidecar_config}" ]]; then
    return 1
  fi
  echo "${sidecar_config}" | grep lifecycle
  if [[ $? -eq 1 ]]; then
    echo "Patching Istio's preStop hook for graceful shutdown"
    echo "${sidecar_config}" | sed 's/\(name: istio-proxy\)/\1\\n    lifecycle:\\n      preStop:\\n        exec:\\n          command: [\\"sh\\", \\"-c\\", \\"sleep 20; while [ $(netstat -plunt | grep tcp | grep -v envoy | wc -l | xargs) -ne 0 ]; do sleep 1; done\\"]/' | oc replace -f -
    oc delete pod -n istio-system -l istio=sidecar-injector
    wait_until_pods_running istio-system || return 1
  fi
  return 0
}

function install_istio(){
  header "Installing Istio"

  # Install the Maistra Operator
  oc create namespace istio-operator
  oc process -f $MAISTRA_RELEASE | oc create -f -

  # Wait until the Operator pod is up and running
  wait_until_pods_running istio-operator || return 1

  # Deploy Istio
  cat <<EOF | oc apply -f -
apiVersion: istio.openshift.com/v1alpha1
kind: Installation
metadata:
  namespace: istio-operator
  name: istio-installation
spec:
  istio:
    authentication: false
    community: true
EOF

  # Wait until at least the istio installer job is running
  wait_until_pods_running istio-system || return 1

  timeout_non_zero 900 'oc get pods -n istio-system && [[ $(oc get pods -n istio-system | grep openshift-ansible-istio-installer | grep -c Completed) -eq 0 ]]' || return 1

  # Scale down unused services deployed by the istio operator. The
  # jaeger pods will fail anyway due to the elasticsearch pod failing
  # due to "max virtual memory areas vm.max_map_count [65530] is too
  # low, increase to at least [262144]" which could be mitigated on
  # minishift with:
  #  minishift ssh "echo 'echo vm.max_map_count = 262144 >/etc/sysctl.d/99-elasticsearch.conf' | sudo sh"
  oc scale -n istio-system --replicas=0 deployment/grafana
  oc scale -n istio-system --replicas=0 deployment/jaeger-collector
  oc scale -n istio-system --replicas=0 deployment/jaeger-query
  oc scale -n istio-system --replicas=0 statefulset/elasticsearch

  patch_istio_for_knative || return 1
  
  header "Istio Installed successfully"
}

function install_knative_build(){
  header "Installing Knative Build"

  oc adm policy add-scc-to-user anyuid -z build-controller -n knative-build
  oc adm policy add-cluster-role-to-user cluster-admin -z build-controller -n knative-build
  oc adm policy add-cluster-role-to-user cluster-admin -z build-pipeline-controller -n knative-build-pipeline

  oc apply -f $BUILD_RELEASE

  wait_until_pods_running knative-build || return 1
  header "Knative Build installed successfully"
}


function install_knative_serving(){
  header "Installing Knative Serving"

  # Grant the necessary privileges to the service accounts Knative will use:
  oc adm policy add-scc-to-user anyuid -z controller -n knative-serving
  oc adm policy add-scc-to-user anyuid -z autoscaler -n knative-serving
  oc adm policy add-cluster-role-to-user cluster-admin -z controller -n knative-serving

  curl -L https://storage.googleapis.com/knative-releases/serving/latest/serving.yaml \
  | sed 's/LoadBalancer/NodePort/' \
  | oc apply --filename -

  enable_knative_interaction_with_registry

  echo ">> Patching istio-ingressgateway"
  oc patch hpa -n istio-system istio-ingressgateway --patch '{"spec": {"maxReplicas": 1}}'

  wait_until_pods_running knative-serving || return 1
  wait_until_service_has_external_ip istio-system istio-ingressgateway || fail_test "Ingress has no external IP"
  header "Knative Serving installed successfully"
}

function install_knative_eventing(){
  header "Installing Knative Eventing"

  # Create knative-eventing namespace, needed for imagestreams
  oc create namespace $EVENTING_NAMESPACE

  # Grant the necessary privileges to the service accounts Knative will use:
  oc annotate clusterrolebinding.rbac cluster-admin 'rbac.authorization.kubernetes.io/autoupdate=false' --overwrite
  oc annotate clusterrolebinding.rbac cluster-admins 'rbac.authorization.kubernetes.io/autoupdate=false' --overwrite

  oc adm policy add-scc-to-user anyuid -z eventing-controller -n $EVENTING_NAMESPACE
  oc adm policy add-scc-to-user anyuid -z in-memory-channel-dispatcher -n $EVENTING_NAMESPACE
  oc adm policy add-scc-to-user anyuid -z in-memory-channel-controller -n $EVENTING_NAMESPACE

  resolve_resources config/ $EVENTING_NAMESPACE eventing-resolved.yaml
  oc apply -f eventing-resolved.yaml

  oc adm policy add-cluster-role-to-user cluster-admin -z eventing-controller -n $EVENTING_NAMESPACE
  oc adm policy add-cluster-role-to-user cluster-admin -z in-memory-channel-dispatcher -n $EVENTING_NAMESPACE
  oc adm policy add-cluster-role-to-user cluster-admin -z in-memory-channel-controller -n $EVENTING_NAMESPACE
  oc adm policy add-cluster-role-to-user cluster-admin -z default -n knative-sources

  echo ">>> Setting SSL_CERT_FILE for Knative Eventing Controller"
  oc set env -n $EVENTING_NAMESPACE deployment/eventing-controller SSL_CERT_FILE=/var/run/secrets/kubernetes.io/serviceaccount/service-ca.crt

  wait_until_pods_running $EVENTING_NAMESPACE || return 1
}

function install_in_memory_channel_provisioner(){
  header "Standing up In-Memory ClusterChannelProvisioner"
  resolve_resources config/provisioners/in-memory-channel/ $EVENTING_NAMESPACE channel-resolved.yaml
  oc apply -f channel-resolved.yaml
}

function install_knative_eventing_sources(){
  header "Installing Knative Eventing Sources"
  oc apply -f ${EVENTING_SOURCES_RELEASE}
  wait_until_pods_running knative-sources || return 1
}

function create_test_resources() {
  echo ">> Ensuring pods in test namespaces can access test images"
  oc policy add-role-to-group system:image-puller system:serviceaccounts:$TEST_NAMESPACE --namespace=$EVENTING_NAMESPACE
  oc policy add-role-to-group system:image-puller system:serviceaccounts:$TEST_FUNCTION_NAMESPACE --namespace=$EVENTING_NAMESPACE

  echo ">> Creating imagestream tags for all test images"
  tag_test_images test/test_images

  #Grant additional privileges
  oc adm policy add-scc-to-user anyuid -z default -n $TEST_FUNCTION_NAMESPACE
  oc adm policy add-scc-to-user privileged -z default -n $TEST_FUNCTION_NAMESPACE
  # oc adm policy add-scc-to-user anyuid -z e2e-receive-adapter -n $TEST_FUNCTION_NAMESPACE
  # oc adm policy add-scc-to-user privileged -z e2e-receive-adapter -n $TEST_FUNCTION_NAMESPACE
}

function resolve_resources(){
  local dir=$1
  local resolved_file_name=$3
  > $resolved_file_name
  for yaml in $(find $dir -maxdepth 1 -name "*.yaml"); do
    echo "---" >> $resolved_file_name
    #first prefix all test images with "test-", then replace all image names with proper repository
    sed -e 's/\(.* image: \)\(github.com\)\(.*\/\)\(test\/\)\(.*\)/\1\2 \3\4test-\5/' $yaml | \
    sed -e 's%github.com/knative/eventing/pkg/provisioners/inmemory/controller%'"$INTERNAL_REGISTRY"'\/'"$EVENTING_NAMESPACE"'\/knative-eventing-in-memory-channel-controller%' | \
    sed -e 's/\(.* image: \)\(github.com\)\(.*\/\)\(.*\)/\1 '"$INTERNAL_REGISTRY"'\/'"$EVENTING_NAMESPACE"'\/knative-eventing-\4/' >> $resolved_file_name
  done

  oc policy add-role-to-group system:image-puller system:serviceaccounts:${EVENTING_NAMESPACE} --namespace=${OPENSHIFT_BUILD_NAMESPACE}

  echo ">> Creating imagestream tags for images referenced in yaml files"
  IMAGE_NAMES=$(cat $resolved_file_name | grep -i "image:" | grep "$INTERNAL_REGISTRY" | awk '{print $2}' | awk -F '/' '{print $3}')
  for name in $IMAGE_NAMES; do
    tag_built_image ${name} ${name} latest
  done
}

function create_test_namespace(){
  oc new-project $TEST_NAMESPACE
  oc adm policy add-scc-to-user privileged -z default -n $TEST_NAMESPACE
  oc new-project $TEST_FUNCTION_NAMESPACE
  oc adm policy add-scc-to-user privileged -z default -n $TEST_FUNCTION_NAMESPACE
}

function enable_knative_interaction_with_registry() {
  local configmap_name=config-service-ca
  local cert_name=service-ca.crt
  local mount_path=/var/run/secrets/kubernetes.io/servicecerts

  oc -n $SERVING_NAMESPACE create configmap $configmap_name
  oc -n $SERVING_NAMESPACE annotate configmap $configmap_name service.alpha.openshift.io/inject-cabundle="true"
  wait_until_configmap_contains $SERVING_NAMESPACE $configmap_name $cert_name
  oc -n $SERVING_NAMESPACE set volume deployment/controller --add --name=service-ca --configmap-name=$configmap_name --mount-path=$mount_path
  oc -n $SERVING_NAMESPACE set env deployment/controller SSL_CERT_FILE=$mount_path/$cert_name
}

function run_e2e_tests(){
  header "Running tests"
  options=""
  (( EMIT_METRICS )) && options="-emitmetrics"
  report_go_test \
    -v -tags=e2e -count=1 -timeout=20m \
    ./test/e2e \
    --tag latest \
    --kubeconfig $KUBECONFIG \
    --dockerrepo ${INTERNAL_REGISTRY}/${EVENTING_NAMESPACE} \
    ${options} || return 1
}

function delete_istio_openshift(){
  echo ">> Bringing down Istio"
  oc delete -n istio-operator installation istio-installation
  #oc process -f $MAISTRA_RELEASE | oc delete --ignore-not-found=true -f -
}

function delete_serving_openshift() {
  echo ">> Bringing down Serving"
  oc delete --ignore-not-found=true -f $SERVING_RELEASE
}

function delete_build_openshift() {
  echo ">> Bringing down Build"
  oc delete --ignore-not-found=true -f $BUILD_RELEASE
}

function delete_test_namespace(){
  echo ">> Deleting test namespace $TEST_NAMESPACE"
  oc adm policy remove-scc-from-user privileged -z default -n $TEST_NAMESPACE
  oc delete project $TEST_NAMESPACE
  echo ">> Deleting test namespace $TEST_FUNCTION_NAMESPACE"
  oc adm policy remove-scc-from-user privileged -z default -n $TEST_FUNCTION_NAMESPACE
  oc delete project $TEST_FUNCTION_NAMESPACE
}

function delete_knative_eventing_sources(){
  header "Brinding down Knative Eventing Sources"
  oc delete --ignore-not-found=true -f $EVENTING_SOURCES_RELEASE
}

function delete_knative_eventing(){
  header "Bringing down Eventing"
  oc delete --ignore-not-found=true -f eventing-resolved.yaml
}

function delete_in_memory_channel_provisioner(){
  header "Bringing down In-Memory ClusterChannelProvisioner"
  oc delete --ignore-not-found=true -f channel-resolved.yaml
}

function teardown() {
  delete_test_namespace
  delete_in_memory_channel_provisioner
  delete_knative_eventing_sources
  delete_knative_eventing
  delete_serving_openshift
  delete_build_openshift
  delete_istio_openshift
}

function tag_test_images() {
  local dir=$1
  image_dirs="$(find ${dir} -mindepth 1 -maxdepth 1 -type d)"

  for image_dir in ${image_dirs}; do
    name=$(basename ${image_dir})
    tag_built_image knative-eventing-test-${name} ${name} e2e

  done
}

function tag_built_image() {
  local remote_name=$1
  local local_name=$2
  local build_tag=$3
  oc tag --insecure=${INSECURE} -n ${EVENTING_NAMESPACE} ${OPENSHIFT_REGISTRY}/${OPENSHIFT_BUILD_NAMESPACE}/stable:${remote_name} ${local_name}:${build_tag}
}


create_test_namespace || exit 1

failed=0

(( !failed )) && install_istio || failed=1

(( !failed )) && install_knative_build || failed=1

(( !failed )) && install_knative_serving || failed=1

(( !failed )) && install_knative_eventing || failed=1

(( !failed )) && install_in_memory_channel_provisioner || failed=1

(( !failed )) && install_knative_eventing_sources || failed=1

(( !failed )) && create_test_resources

(( !failed )) && run_e2e_tests || failed=1

(( failed )) && dump_cluster_state

teardown

(( failed )) && exit 1

success