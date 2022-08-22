#!/usr/bin/env bash

set -e

kind_control_plane_name='kind-control-plane'
reg_name='kind-registry'
reg_port='5000'
nginx_port='8443'
default_hostname=$(hostname)
nginx_name=$default_hostname

generate_tls() {
  git clone https://github.com/rabbitmq/tls-gen.git
  pushd tls-gen/basic
  # create certificates
  make
  popd
}

create_nginx_conf() {
  pushd tls-gen/basic
  mkdir -p nginx/conf
  mkdir -p nginx/certs

  cp result/server_* nginx/certs

  # useful to redirect http traffic to https
  # https://stackoverflow.com/questions/8768946/dealing-with-nginx-400-the-plain-http-request-was-sent-to-https-port-error
  # curl -kvL http://juans-macbook-pro.local:8443/v2/apps/hello-yeti/manifests/latest will redirect to https
  cat << EOF > nginx/conf/my_server_block_reverse_proxy.conf
server {
    listen       $nginx_port ssl;
    server_name $default_hostname;

    ssl_certificate      bitnami/certs/server_${default_hostname}_certificate.pem;
    ssl_certificate_key  bitnami/certs/server_${default_hostname}_key.pem;

    # this will forward request on http://server_name:8443/what_ever to https://server_name:8443/what_ever
    error_page 497 301 =307 https://\$server_name:\$server_port\$request_uri;

    ssl_session_cache    shared:SSL:1m;
    ssl_session_timeout  5m;

    ssl_ciphers  HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers  on;

    location / {
        proxy_pass http://$reg_name:$reg_port;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }
  }

EOF
  popd
}

run_nginx() {
  pushd tls-gen/basic
  running=$(docker inspect -f '{{.State.Running}}' "${nginx_name}" 2>/dev/null || true)
  if [ "${running}" != 'true' ]; then
    # when the kind cluster is created, it also creates a docker network named "kind". We need to run
    # the nginx within that network too
    docker run --rm -d --net kind --name "$nginx_name" \
      -v "$PWD/nginx/conf/my_server_block_reverse_proxy.conf:/opt/bitnami/nginx/conf/server_blocks/my_server_block.conf:ro" \
      -v "$PWD/nginx/certs:/certs" \
      -p 8443:8443 \
      bitnami/nginx:latest
  else
    echo "$nginx_name already running"
  fi
  popd
}


add_ca_to_k8s() {
  pushd tls-gen/basic
  # copy the ca cert to kind container
  docker cp "$PWD/result/ca_certificate.pem" "$kind_control_plane_name:/usr/local/share/ca-certificates/ca_certificate.crt"
  # update the ca certificates on the container
  docker exec -it $kind_control_plane_name update-ca-certificates
  # we need to restart the containerd deamon for k8s to recognize the new ca
  docker exec -it $kind_control_plane_name systemctl restart containerd
  popd
}

# Taken from https://kind.sigs.k8s.io/docs/user/local-registry/
create_kind_cluster_and_local_registry() {
  version=${KIND_VERSION:-v1.23.6}
  # create registry container unless it already exists
  if [ "$(docker inspect -f '{{.State.Running}}' "${reg_name}" 2>/dev/null || true)" != 'true' ]; then
    docker run \
      -d --restart=always -p "127.0.0.1:${reg_port}:5000" --name "${reg_name}" \
      registry:2
  fi

  # create a cluster with the local registry enabled in containerd
  cat <<EOF | kind create cluster --image=kindest/node:"${version}" --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
containerdConfigPatches:
- |-
  [plugins."io.containerd.grpc.v1.cri".registry.mirrors."localhost:${reg_port}"]
    endpoint = ["http://${reg_name}:5000"]
EOF

  # connect the registry to the cluster network if not already connected
  if [ "$(docker inspect -f='{{json .NetworkSettings.Networks.kind}}' "${reg_name}")" = 'null' ]; then
    docker network connect "kind" "${reg_name}"
  fi

  # Document the local registry
  # https://github.com/kubernetes/enhancements/tree/master/keps/sig-cluster-lifecycle/generic/1755-communicating-a-local-registry
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "localhost:${reg_port}"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
EOF

}

setup_nginx() {
  generate_tls
  create_nginx_conf
  run_nginx
  add_ca_to_k8s
}

"$@"
