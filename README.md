# How to create a local kind registry with https

1. First we need to have a local kind registry and a kind cluster that are able to communicate with each other.

Run:
```shell
./docker_registry_https.sh create_kind_cluster_and_local_registry

```

If the registry is already running then it will not spin up a new one.

2. As far as I know this kind registry does not support https. So, the alternative is to have a nginx server
   setup with TLS certificate and reverse proxy the request to the kind registry.

This can be easily done with this script
```shell
./docker_registry_https.sh setup_nginx

```

With this two steps we will have
1. docker container `kind-control-plane` with a KinD cluster running
2. docker container `kind-registry` with a kind registry running on port `5000`
3. docker network `kind` that allows connectivity between these to containers
4. docker container with name with whatever your `$(hostname)` is. This container 
   is running a nginx server with https running on port `8443`. This server
   is setup to run forward all requests to `http://kind-registry:5000`.
5. Try to run `curl -k https://$(hostname):8443/v2/` you should see an empty object response. 

## Push images to the registry
For some reason I do not know, this configuration does not allow us to push to the registry
using the secure port `8443`.
To push images you need to do it through the unsecure port `5000`.

Let suppose your `$(hostname)` is `my-awesome-machine.local`.


If you push the image to `my-awesome-machine.local:5000/apps/backend-app:latest`

Then to create a Deployment you can do it like this:

```yaml
---
apiVersion: apps/v1
kind: Deployment
metadata:
  labels:
    app: backend-app
  name: backend-app
spec:
  replicas: 1
  selector:
    matchLabels:
      app: backend-app
  template:
    metadata:
      labels:
        app: backend-app
    spec:
      containers:
        - image: my-awesome-machine.local:8443/apps/backend-app:latest
          name: backend-app

```

Thus, the KinD cluster will pull the image using the https port.
