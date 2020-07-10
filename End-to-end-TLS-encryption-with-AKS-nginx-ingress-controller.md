# End-to-End TLS Encryption With AKS Nginx Ingress Controller

Version: 1.0

Last Modified: 4th June 2020

[[_TOC_]]

## Introduction

Most organization's security framework mandates encryption at rest and in transit. For web traffic,**TLS 1.2** is required at a minimum. Data encryption is allowed to be terminated in memory and then re-encrypted at a Load Balancer or Web Application Firewall.
This guide will help you create a POC environment to configure end to end ssl for AKS with path and host based routing.

## Scenario

1. Ingress deploymnet behind the Private endpoint. Nginx is slelected as ingress controller at present because appGW does not support private endpoint.
2. Two type of routing Path base and Host base.
3. End-to-End encyption required though certificates and certificates are stored in Azure KV.
4. CSI secret store dirvers are used to download the certs from KV and build kubernetes secrets which are presented to ingress POD.  
5. System Managed indentity are utilized to access the KV and its sub objects.  

## Objectives

* Deploy a private AKS cluster with multiple services and nginx as ingress controller
* Achieve end-to-end TLS encryption
* Certificates for listner configuration in nginx must be fetched from azure keyvault
* Achieve host based and path based routing through a single nginx controller

## Challenge

When an ingress controller listner configurations needs to be secured with TLS, a [kubernetes.io/tls]() type secret needs to be passed to the ingress manifest. This [kuberneters.io/tls]() consists of two parts. A crt file which contains the certificate signature without the private key. And the key file which contains the private key for the crt file.
We intend to utilize azure keyvault as a certificate store. However, key-vault expects the cert in pem+x509 key format whereas nginx expects certificate in pem and key file separate.ly Due to this mismatch in imported vs expected format, nginx is unable to use that certificate synced from key-vault.

## Solution

[Azure Key Vault Provider for Secrets Store CSI Driver](https://github.com/Azure/secrets-store-csi-driver-provider-azure/blob/master/README.md) can be utilized to fetch the secret from azure keyvault and create kubernetes secret to mirror the content of the mounted secret. This [kubernetes.io/tls]() secret inturn can be passed to the ingress controller to secure the listner configuration.

## Proof Of Concept

### Tools Used

* For management and infra deployment windows server 2016 is used.
* [Az CLI](https://docs.microsoft.com/en-us/cli/azure/install-azure-cli-windows?view=azure-cli-latest) Version 2.6.0
* [Windows Powershell](https://www.microsoft.com/en-us/download/details.aspx?id=54616) Version 5.1
* [Kubectl](https://kubernetes.io/docs/tasks/tools/install-kubectl/#install-kubectl-on-windows) Version 1.18 
* [Helm](https://helm.sh/docs/intro/install/) Version 3.2.1
* [Secret store csi drivers](https://github.com/Azure/secrets-store-csi-driver-provider-azure/blob/master/charts/csi-secrets-store-provider-azure/README.md)

### Prerequsites
* Download the certs from [github](https://github.com/manish-anand-n/aks-ssl-nginx)

### Deployment

The deployment consists of three services

- demositeroot - An nginx custom image configured to listen on host [demosite.aksinternal.com/]() on port 443 with pre configured certificate.
- demositepath - An nginx custom image configured to listen on host [demosite.aksinternal.com/hello]() on port 443 with pre configured certificate.
- demosite2 - An nginx custom image configured to listen on host [demosite2.aksinternal.com/hello]() on port 443 with pre configured certificate.

And ingress will be deployed with end-to-end TLS encryption, with both host based and path based routing.

- Host [demosite.aksinternal.com]() should routed to demositeroot service.
- Host+path [demosite.aksinternal.com/hello]() should be routed to demositepath service.
- Host [demosite2.aksinternal.com]() should be routed to demosite2 service.

Since ingress will be configured with secure listners, [kubernetes.io/tls]() secrets will be created for [demosite.aksinternal.com]() and [demosite2.aksinternal.com]() hostnames using secret store csi driver provider for azure.

We will start the deployment with loging into azure using azure cli and declaring required variables.

```
# login to azure
az login
# Set your subscription if you want to set context to a particular sub
# az account set --subscription <sub id>
# Declare variables
$aks_name = "aksinternal" # AKS Name to be created 
$aks_rg = "kube" # AKS resource Group name to be created
$vnet_name = "kube-vnet" # AKS vnet name to be created
$location = "eastus2" # AKS location
$kv = "akskv" # Keyvault name to be created
$demosite1_secret_name = "demosite1cert" # KV 1st secret name
$demosite2_secret_name = "demosite2cert" # KV 2nd secret name
$site1pem = "C:\sslingress\demosite1.pem" # Path to the 1st PEM file
$site2pem = "C:\sslingress\demosite2.pem" # Path to the 2nd PEM file
$namespace = "ingress-basic" #namespace name to be create in AKS
```

Deploy the resource group and virtual network for the AKS deployment.

```
# Get context to be utilized later
$context = (az account show | ConvertFrom-Json)
# Create resourcegroup
az group create -n $aks_rg -l $location
# Create network
$vnet = (az network vnet create -n $vnet_name -g $aks_rg --address-prefixes 10.0.0.0/8 --location $location --subnet-name kube --subnet-prefixes 10.240.0.0/16 | ConvertFrom-Json)
# Create a subnet for keyvault private endpoint
az network vnet subnet create --address-prefixes 10.241.0.0/24 -n PE-Subnet -g $aks_rg --vnet-name $vnet_name
# Update the vnet for private link endpoint policy
az network vnet subnet update -n PE-Subnet --vnet-name $vnet_name -g $aks_rg --disable-private-endpoint-network-policies
```

Deploy the AKS cluster.

```
# Create aks cluster
az aks create --resource-group $aks_rg --name $aks_name --load-balancer-sku standard --enable-private-cluster --network-plugin azure --vnet-subnet-id $vnet.newVNet.subnets.id --docker-bridge-address 172.17.0.1/16 --dns-service-ip 10.0.0.10 --service-cidr 10.0.0.0/16 --node-count 1 --location $location --node-vm-size Standard_B2s --nodepool-name $($aks_name) --kubernetes-version 1.16.9 --generate-ssh-keys
# Get aks object 
$aks = (az aks show -n $aks_name -g $aks_rg | ConvertFrom-Json)
```

> _Note: Make necessary DNS and connectivity changes so that the management server can talk to the private AKS cluster._

Fetch AKS credentials and validate connectivity.

```
# Get aks creds
az aks Get-Credentials -n $aks_name -g $aks_rg --overwrite-existing
# Validate connectivity
kubectl get nodes
```

Create azure keyvault to store the certificates.

```
# Create a new KV
az keyvault create -n $kv -g $aks_rg --location $location --sku standard
# Get existing keyvault id for role and access policy assignement
$kv_id = (az keyvault show -n $kv -g $aks_rg | ConvertFrom-Json).id
```

Enable AKS VMSS managed identity and assign Reader permission on azure keyvault with access policy set to get on secret, certificates and keys.

```
# Get vmss details to enable system managed idetity
$vmss = (az vmss list -g $aks.nodeResourceGroup | convertfrom-json)
# Enable vmss identity and assign Reader RBAC of KV
az vmss identity assign -g $aks.nodeResourceGroup -n $vmss.name --role Reader --scope $kv_id
# Get vmss principle id
$vmss_id = (az vmss identity show -n $vmss.name -g $aks.nodeResourceGroup | ConvertFrom-Json)
# Assign keyvault access policy
# Get appid of the vmss identity object
$vmss_spn = (az ad sp show --id $vmss_id.principalId | convertfrom-json)
# Assign keyvault access policy for key,secret and cert
az keyvault set-policy -n $kv --key-permissions get --object-id $vmss_id.principalId
az keyvault set-policy -n $kv --secret-permissions get --object-id $vmss_id.principalId
az keyvault set-policy -n $kv --certificate-permissions get --object-id $vmss_id.principalId
```

Upload the pem files to azure as certificates.

```
# Upload the pem files as certificates to azure kv
az keyvault certificate import --vault-name $kv -n $demosite1_secret_name -f $site1pem
az keyvault certificate import --vault-name $kv -n $demosite2_secret_name -f $site2pem
```

> _Note: The pem files must have both certificate and private key inside them. You can validate this by opening the pem file in any test editor and examining the content.\
> -----BEGIN CERTIFICATE-----\
> certificate content\
> -----END CERTIFICATE-----\
> -----BEGIN PRIVATE KEY-----\
> Private key\
> -----END PRIVATE KEY-----_

Create the private endpoint for keyvault access. Deploy the private dns zone with A record and network link integrated to AKS vnet for private dns resolution.

```
# Create private endpoint for the keyvault access
az network private-endpoint create --connection-name tokv -n kvpe --private-connection-resource-id $kv_id -g $aks_rg --subnet PE-Subnet --vnet-name $vnet_name --group-id vault
$pe_ip = (az network private-endpoint show -n kvpe -g $aks_rg | convertfrom-json)
# Create a private dns zone for keyvault DNS resolution
az network private-dns zone create -g $aks_rg -n privatelink.vaultcore.azure.net
# Add a record for keyvault
az network private-dns record-set a add-record -g $aks_rg -z privatelink.vaultcore.azure.net -n $kv -a $pe_ip.customDnsConfigs.ipaddresses
# Link the private dns zone with kube-vnet
az network private-dns link vnet create -g $aks_rg -n kvnetlink -z privatelink.vaultcore.azure.net -v $vnet_name -e false
```

Make sure that [Helm](https://helm.sh/docs/intro/install/) is installed on the system, and proceed with namespace creation in AKS.

```
# Create namespace
kubectl create ns $namespace
```

Add appropriate repos in helm to install nginx ingress and csi secret store provider for azure.

```
# Add repo to helm
helm repo add stable https://kubernetes-charts.storage.googleapis.com/
helm repo add csi-secrets-store-provider-azure https://raw.githubusercontent.com/Azure/secrets-store-csi-driver-provider-azure/master/charts
# Update helm repo
helm repo update
```

Create an internal load balancer manifest.

```
# Create internal controller yaml manifest
$internal_controller = @"
controller:
  service:
    loadBalancerIP: xx.xx.xx.xx
    annotations:
      service.beta.kubernetes.io/azure-load-balancer-internal: "true"
"@
# Create a file for the manifest
$internal_controller | Out-File C:\sslingress\internal-controller.yaml
```

Install nginx controller with helm and verify that it has the proper ip address.

```
# Install nginx controller using helm
helm install nginx-ingress stable/nginx-ingress --namespace $namespace -f C:\sslingress\internal-controller.yaml --set controller.replicaCount=2 --set controller.nodeSelector."beta\.kubernetes\.io/os"=linux --set defaultBackend.nodeSelector."beta\.kubernetes\.io/os"=linux
# Verify the controller got an ip address
Kubectl get service -n $namespace
```

Deploy csi secret provider class for azure keyvault and verify that pods are running.

```
# Install csi secret store provider for azure
helm install csi-secrets-store-provider-azure/csi-secrets-store-provider-azure --generate-name --namespace $namespace
# Verify pods for csi
kubectl get pods -n $namespace
```

Create the SecretProviderClass and verify its creation.

```
# Create secret provider class
$csidriver = @"
apiVersion: secrets-store.csi.x-k8s.io/v1alpha1
kind: SecretProviderClass
metadata:
  name: demosite1
spec:
  provider: azure
  secretObjects:
    - secretName: demosite1
      type: kubernetes.io/tls
      data:
        - objectName: $($demosite1_secret_name)
          key: tls.key
        - objectName: $($demosite1_secret_name)
          key: tls.crt
  parameters:
    usePodIdentity: "false"
    useVMManagedIdentity: "true"
    userAssignedIdentityID: $($vmss_spn.appId)
    keyvaultName: $($kv)
    objects: |
      array:
        - |
          objectName: $($demosite1_secret_name)
          objectType: secret
    tenantId: $($context.tenantId)
---
apiVersion: secrets-store.csi.x-k8s.io/v1alpha1
kind: SecretProviderClass
metadata:
  name: demosite2
spec:
  provider: azure
  secretObjects:
    - secretName: demosite2
      type: kubernetes.io/tls
      data:
        - objectName: $($demosite2_secret_name)
          key: tls.key
        - objectName: $($demosite2_secret_name)
          key: tls.crt
  parameters:
    usePodIdentity: "false"
    useVMManagedIdentity: "true"
    userAssignedIdentityID: $($vmss_spn.appId)
    keyvaultName: $($kv)
    objects: |
      array:
        - |
          objectName: $($demosite2_secret_name)
          objectType: secret
    tenantId: $($context.tenantId)
"@
# Deploy SecretProviderClass manifest
$csidriver | kubectl apply -n $namespace -f -
# Verify the SecretProviderClass is created
kubectl get SecretProviderClass -n $namespace
```

> Note: The secret provider class is fetching the certificates stored in keyvault. When invoked through volume mounts in aks service, will create [kubernetes.io/tls]() secrets for us to be consumed by the ingress controller.

Create the services.

```
# Create the manifest for the services to be deployed
$sites = @"
apiVersion: apps/v1
kind: Deployment
metadata:
  name: demositeroot
spec:
  replicas: 1
  selector:
    matchLabels:
      app: demositeroot
  template:
    metadata:
      labels:
        app: demositeroot
    spec:
      containers:
        - name: demositeroot
          image: inf4m0us/mypubrepo:1
          ports:
            - containerPort: 443
          volumeMounts:
            - name: secrets-store-inline
              mountPath: "/mnt/secrets-store"
              readOnly: true
      volumes:
        - name: secrets-store-inline
          csi:
            driver: secrets-store.csi.k8s.io
            readOnly: true
            volumeAttributes:
              secretProviderClass: "demosite1"

---
apiVersion: v1
kind: Service
metadata:
  name: demositeroot
spec:
  type: ClusterIP
  ports:
    - port: 443
  selector:
    app: demositeroot
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: demopath
  annotations:
    service.beta.kubernetes.io/azure-load-balancer-internal: "true"
spec:
  replicas: 1
  selector:
    matchLabels:
      app: demopath
  template:
    metadata:
      labels:
        app: demopath
    spec:
      containers:
        - name: demopath
          image: inf4m0us/mypubrepo:2new
          ports:
            - containerPort: 443
          volumeMounts:
            - name: secrets-store-inline
              mountPath: "/mnt/secrets-store"
              readOnly: true
      volumes:
        - name: secrets-store-inline
          csi:
            driver: secrets-store.csi.k8s.io
            readOnly: true
            volumeAttributes:
              secretProviderClass: "demosite1"
---
apiVersion: v1
kind: Service
metadata:
  name: demopath
spec:
  type: ClusterIP
  ports:
    - port: 443
  selector:
    app: demopath
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: demosite2
  annotations:
    service.beta.kubernetes.io/azure-load-balancer-internal: "true"
spec:
  replicas: 1
  selector:
    matchLabels:
      app: demosite2
  template:
    metadata:
      labels:
        app: demosite2
    spec:
      containers:
        - name: demosite2
          image: inf4m0us/mypubrepo:3
          ports:
            - containerPort: 443
          volumeMounts:
            - name: secrets-store-inline
              mountPath: "/mnt/secrets-store"
              readOnly: true
      volumes:
        - name: secrets-store-inline
          csi:
            driver: secrets-store.csi.k8s.io
            readOnly: true
            volumeAttributes:
              secretProviderClass: "demosite2"
---
apiVersion: v1
kind: Service
metadata:
  name: demosite2
spec:
  type: ClusterIP
  ports:
    - port: 443
  selector:
    app: demosite2
"@
# Deploy the services
$sites | kubectl apply -n $namespace -f -
```

Verify that the pods are in running state.

```
# Verify the pods are created and are running successfully
kubectl get pods -n $namespace
```

Verify that the secrets have been created.

```
# Check the secrets are create or not
kubectl get secret -n $namespace
```

> Note: Once the pods of the service are in running state, they will invoke the SecretClassProvider to create the appropriate kubernetes secrets. You can exec into the pods and check the volume mount as well to verify that the pem file is mounted on the pods.
>
> ```
> kubectl exec -it -n $namespace <podname> -- cat /mnt/secrets-store/demosite1cert
> ```

Final step is to deploy the ingress which will refer to the kubenetest.io/tls secrets created in the previous steps to secure the connection.

```
# Deploy ingress controller
$ingress = @"
apiVersion: extensions/v1beta1
kind: Ingress
metadata:
  name: my-ingress
  namespace: $($namespace)
  annotations:
    kubernetes.io/ingress.class: nginx
    nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"
spec:
  tls:
  - hosts:
    - demosite.aksinternal.com
    secretName: demosite1
  - hosts:
    - demosite2.aksinternal.com
    secretName: demosite2
  rules:
  - host: demosite.aksinternal.com
    http:
      paths:
      - backend:
          serviceName: demositeroot
          servicePort: 443
        path: /
      - backend:
          serviceName: demopath
          servicePort: 443
        path: /hello
  - host: demosite2.aksinternal.com
    http:
      paths:
      - backend:
          serviceName: demosite2
          servicePort: 443
        path: /
"@
$ingress | kubectl apply -f -
# Get ingress ip
kubectl get service -n $namespace
```

Once the environment is deployed, configure the service hostname dns resolution to the internal loadbalancer ip.

Create DNS records for [demosite.aksinternal.com]() and [demosite2.aksinternal.com]() to point to the loadbalancer ip. Using curl or web browser access the websites https://demosite.aksinternal.com , https://demosite.aksinternal.com/hello and https://demosite2.aksinternal.com. Verifiy the certificate presented by the websites.

## sources
PEM files and deployment powershell script can be downloaded from [github](https://github.com/manish-anand-n/aks-ssl-nginx)
