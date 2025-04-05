# Infrastructure Definition

[![quality](https://github.com/cash-track/infra/actions/workflows/quality.yml/badge.svg?branch=main&event=push)](https://github.com/cash-track/infra/actions/workflows/quality.yml) [![deploy](https://github.com/cash-track/infra/actions/workflows/deploy.yml/badge.svg?branch=main&event=push)](https://github.com/cash-track/infra/actions/workflows/deploy.yml)

## Configure kubectl using doctl

```shell
$ doctl kubernetes cluster kubeconfig save k8s-cash-track
$ kubectl config current-context
```


### Default Namespace (optional)

Configure default namespace to avoid adding `-n namespace-name` every time

```shell
$ kubectl config get-users      # copy name of the user
$ kubectl config get-clusters   # copy name of the cluster
$ kubectl config set-context prod --namespace=cash-track --cluster={cluster} --user={user}  # use previously copied values
$ kubectl config use-context prod
```


## Dependencies

DigitalOcean managed cluster is used.


### Nginx Ingress

```shell
$ kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.8.1/deploy/static/provider/do/deploy.yaml
```

#### Upgrade

```shell
$ kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.10.1/deploy/static/provider/do/deploy.yaml
```

Note. If you see some errors like "field is immutable", check for which k8s resources the error is. Most likely
you can delete old resource and try to apply again.

Note. If you don't see `nginx_*` metrics, make sure `--enable-metrics=true` is set for ingress-nginx-controller pod arguments.

### Cert Manager

```shell
$ kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.9.1/cert-manager.yaml
```

#### Upgrade

```shell
$ kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.15.1/cert-manager.yaml
```


### Metrics Server

```shell
$ kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
```


### GitHub Actions Runner Controller

```shell
$ helm repo add actions-runner-controller https://actions-runner-controller.github.io/actions-runner-controller
$ # or
$ helm repo update actions-runner-controller https://actions-runner-controller.github.io/actions-runner-controller
$ # then
$ helm upgrade --install --namespace actions-runner-system --create-namespace \
             --wait actions-runner-controller actions-runner-controller/actions-runner-controller \
             --set "githubWebhookServer.enabled=true"
```

Generate secret

```shell
$ cp common/actions-runner/.github-runner-secret.yml.example common/actions-runner/github-runner-secret.yml
```

Add GitHub personal access token to `common/actions-runner/github-runner-secret.yml`. Make sure you added all required permissions (see https://github.com/actions-runner-controller/actions-runner-controller#deploying-using-pat-authentication).

#### Update Secret

Regenerate your GitHub personal access token in [Tokens](https://github.com/settings/tokens) page. Once done encode it using Base64 encoding:

```shell
$ echo -n 'your-personal-access-token' | base64
```

Update Base64 encoded token in `common/actions-runner/github-runner-secret.yml` file then execute

```shell
$ kubectl apply -f common/actions-runner/github-runner-secret.yml
$ kubectl rollout restart -n actions-runner-system deployment/actions-runner-controller
```

#### Upgrade

See https://github.com/actions/actions-runner-controller/blob/master/charts/actions-runner-controller/docs/UPGRADING.md

```shell
$ # REMEMBER TO UPDATE THE CHART_VERSION TO RELEVANT CHART VERSION!!!!
$ CHART_VERSION=0.23.3
$ 
$ curl -L https://github.com/actions/actions-runner-controller/releases/download/actions-runner-controller-0.23.3/actions-runner-controller-0.23.3.tgz | tar zxv --strip 1 actions-runner-controller/crds
$ 
$ kubectl replace -f crds/
$ 
$ # helm upgrade [RELEASE] [CHART] [flags]
$ helm upgrade actions-runner-controller \
  actions-runner-controller/actions-runner-controller \
  --install \
  --namespace actions-runner-system \
  --version ${CHART_VERSION}
 ```

### Tailscale

Optionally to allow accessing internal cluster resources through tunnel Tailscale can be installed on cluster as an operator that exposes resources

Follow [instruction](https://tailscale.com/kb/1236/kubernetes-operator) where you'll get OAuth credentials to prepare and execute:

```shell
$ helm repo add tailscale https://pkgs.tailscale.com/helmcharts
$ helm repo update
$ helm upgrade \
  --install \
  tailscale-operator \
  tailscale/tailscale-operator \
  --namespace=tailscale \
  --create-namespace \
  --set-string oauth.clientId="{OAuth-Client-ID}" \
  --set-string oauth.clientSecret="{OAuth-Client-Secret}" \
  --wait
```

Now to expose any of your `Service` to the internal network add annotations

```yaml
metadata:
  annotations:
    tailscale.com/expose: 'true'
    tailscale.com/hostname: ct-prod-grafana # Follow convention `ct-prod-{service-name}`
```

As soon as Tailscale connected on the device, service should be accessible as `http://cp-prod-grafana`

#### Troubleshooting

In case for existing service configured to expose does not appear in tailnet - recreate it:

```shell
$ kubectl delete -n monitoring service alertmanager
$ kubectl apply -f services/alertmanager/service.yml
```

To enable operator's debug logs add operator config to the original installation command (before `--wait`):
```shell
--set operatorConfig.logging=debug
```


## Production

Namespace: `cash-track`.

### Prepare Secrets

Generate secrets definition

```shell
$ cp common/configs/.secret.yml.example common/configs/secret.yml
$ cp common/configs/.cloudflare-secret.yml.example common/configs/cloudflare-secret.yml
$ cp services/api/.secret.yml.example services/api/secret.yml
$ cp services/mysql/.secret.yml.example services/mysql/secret.yml
$ cp services/mysql-exporter/.secret.yml.example services/mysql-exporter/secret.yml
```

Configure values for every created files

- `common/configs/secret.yml`
- `common/configs/cloudflare-secret.yml`
- `services/api/secret.yml`
- `services/mysql/secret.yml`
- `services/mysql-exporter/secret.yml`

Every `data` value of a secret must be BASE64 encoded:

```shell
$ echo -n 'admin' | base64
```


### Setup

```shell
$ kubectl create -n monitoring configmap prometheus-configs --from-file=./services/prometheus/configs -o yaml --dry-run=client | kubectl apply -f -
$ kubectl create -n monitoring configmap alertmanager-configs --from-file=./services/alertmanager/configs -o yaml --dry-run=client | kubectl apply -f -
$ kubectl create -n monitoring configmap grafana-configs --from-file=./services/grafana/configs -o yaml --dry-run=client | kubectl apply -f -
$ kubectl create -n monitoring configmap grafana-loki-configs --from-file=./services/grafana-loki/configs -o yaml --dry-run=client | kubectl apply -f -
$ kubectl create -n monitoring configmap grafana-tempo-configs --from-file=./services/grafana-tempo/configs -o yaml --dry-run=client | kubectl apply -f -
$ kubectl create -n monitoring configmap promtail-configs --from-file=./services/promtail/configs -o yaml --dry-run=client | kubectl apply -f -
```

```shell
$ kubectl apply -f ./common/namespace.yml
$ kubectl apply -R -f ./common
$ kubectl apply -f ./services/prometheus
$ kubectl apply -f ./services/node-exporter
$ kubectl apply -f ./services/grafana
$ kubectl apply -f ./services/grafana-loki
$ kubectl apply -f ./services/grafana-tempo
$ kubectl apply -f ./services/promtail
$ kubectl apply -f ./services/alertmanager
$ kubectl apply -f ./services/redis 
$ kubectl apply -f ./services/mysql 
$ kubectl apply -f ./services/mysql-backup 
$ kubectl apply -f ./services/mysql-exporter 
$ kubectl apply -f ./services/api
$ kubectl apply -f ./services/gateway
$ kubectl apply -f ./services/website
$ kubectl apply -f ./services/frontend
$ kubectl exec deployments/api -it -- php app.php migrate
```


### Deploy

To follow deployment process for every new version once initial setup is done use commands per each service defined 

#### API

```shell
$ kubectl set image deployment/api api=cashtrack/api:1.2.9    # Deploy new tag
$ kubectl rollout status deployment/api                       # Watch deployment status
$ kubectl rollout undo deployment/api                         # Rollback current deployment
$ kubectl rollout history deployment/api                      # List past deployment revision
$ kubectl rollout restart deployment/api                      # Redeploy currently deployed tag
```

```shell
$ kubectl exec deployments/api -it -- php app.php cache:clean
$ kubectl exec deployments/api -it -- php app.php migrate
$ kubectl exec deployments/api -it -- php app.php newsletter:send Newsletter\\TelegramChannelMail --test 1
```

#### Gateway

```shell
$ kubectl set image deployment/gateway gateway=cashtrack/gateway:1.2.9    # Deploy new tag
$ kubectl rollout status deployment/gateway                               # Watch deployment status
$ kubectl rollout undo deployment/gateway                                 # Rollback current deployment
$ kubectl rollout history deployment/gateway                              # List past deployment revision
$ kubectl rollout restart deployment/gateway                              # Redeploy currently deployed tag
```

#### Website

```shell
$ kubectl set image deployment/website website=cashtrack/website:0.1.14   # Deploy new tag
$ kubectl rollout status deployment/website                               # Watch deployment status
$ kubectl rollout undo deployment/website                                 # Rollback current deployment
$ kubectl rollout history deployment/website                              # List past deployment revision
$ kubectl rollout restart deployment/website                              # Redeploy currently deployed tag
```

#### Frontend

```shell
$ kubectl set image deployment/frontend frontend=cashtrack/frontend:1.1.4  # Deploy new tag
$ kubectl rollout status deployment/frontend                               # Watch deployment status
$ kubectl rollout undo deployment/frontend                                 # Rollback current deployment
$ kubectl rollout history deployment/frontend                              # List past deployment revision
$ kubectl rollout restart deployment/frontend                              # Redeploy currently deployed tag
```

#### MySQL

```shell
$ kubectl set image statefulset/mysql mysql=cashtrack/mysql:1.0.8           # Deploy new tag of MySQL
$ kubectl rollout status statefulset/mysql                                  # Watch deployment status
$ kubectl rollout undo statefulset/mysql                                    # Rollback current deployment
$ kubectl rollout history statefulset/mysql                                 # List past deployment revision
$ kubectl rollout restart statefulset/mysql                                 # Redeploy currently deployed tag
```

#### MySQL Backup

```shell
$ kubectl set image deployment/mysql-backup backup=cashtrack/mysql-backup:0.0.5   # Deploy new tag of Backup
$ kubectl rollout status deployment/mysql-backup                                  # Watch deployment status
$ kubectl rollout undo deployment/mysql-backup                                    # Rollback current deployment
$ kubectl rollout history deployment/mysql-backup                                 # List past deployment revision
$ kubectl rollout restart deployment/mysql-backup                                 # Redeploy currently deployed tag
```

Commands: 

```shell
$ kubectl exec deployment/mysql-backup -it -- php app.php list
$ kubectl exec deployment/mysql-backup -it -- php app.php backup
$ kubectl exec deployment/mysql-backup -it -- php app.php restore <id>
$ kubectl exec deployment/mysql-backup -it -- php app.php clear --days=7
```

#### Redis

```shell
$ kubectl set image statefulset/redis redis=cashtrack/redis:1.0.1           # Deploy new tag of Redis
$ kubectl rollout status statefulset/redis                                  # Watch deployment status
$ kubectl rollout undo statefulset/redis                                    # Rollback current deployment
$ kubectl rollout history statefulset/redis                                 # List past deployment revision
$ kubectl rollout restart statefulset/redis                                 # Redeploy currently deployed tag
```

## Troubleshooting

```shell
$ kubectl port-forward service/mysql 33060:3306               # Connect to MySQL from local
$ kubectl port-forward service/redis 63790:6379               # Connect to Redis from local
$ kubectl exec pods/mysql-0 -it -- bash                       # SSH into a Pod
$ kubectl exec pods/mysql-0 --container backup -it -- bash    # SSH into a specific container of a Pod
```

### Exposed Services to internal

The list of exposed services available via Tailscale.

- AlertManager: [http://ct-prod-alertmanager:9093](http://ct-prod-alertmanager:9093)
- Grafana: [http://ct-prod-grafana:80](http://ct-prod-grafana:80)
- Prometheus: [http://ct-prod-prometheus:9090](http://ct-prod-prometheus:9090)
- MySQL: `tcp://ct-prod-mysql:3306`
- Redis: `tcp://ct-prod-redis:6379`
- MySQL: `tcp://tb-prod-mysql:3306` (Telegram bots)

### Pod stuck in `Terminating` state

```shell
$ kubectl delete pods <pod> --grace-period=0 --force            # First try to force remove <pod>
$ kubectl patch pod <pod> -p '{"metadata":{"finalizers":null}}' # If first attempt didn't work, try this one
```

### Cert Manager stuck in not ready

If you see certain logs in the pod output repeated many times:

```
"Failed to generate serving certificate, retrying..." err="internal error: CA certificate has expired, try again later"
```

Run the following command to trigger regenerate CA

```shell 
$ kubectl delete secret -n cert-manager cert-manager-webhook-ca
```
