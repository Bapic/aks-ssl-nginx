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
$namespace = "ingress-basic"

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
# Create aks cluster
az aks create --resource-group $aks_rg --name $aks_name --load-balancer-sku standard --enable-private-cluster --network-plugin azure --vnet-subnet-id $vnet.newVNet.subnets.id --docker-bridge-address 172.17.0.1/16 --dns-service-ip 10.0.0.10 --service-cidr 10.0.0.0/16 --node-count 1 --location $location --node-vm-size Standard_B2s --nodepool-name $($aks_name) --kubernetes-version 1.16.9 --generate-ssh-keys
# Get aks object 
$aks = (az aks show -n $aks_name -g $aks_rg | ConvertFrom-Json)
# Get aks creds
az aks Get-Credentials -n $aks_name -g $aks_rg --overwrite-existing
# Validate connectivity
kubectl get nodes
# Create a new KV
az keyvault create -n $kv -g $aks_rg --location $location --sku standard
# Get existing keyvault id for role and access policy assignement
$kv_id = (az keyvault show -n $kv -g $aks_rg | ConvertFrom-Json).id
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
# Upload the pem files as certificates to azure kv
az keyvault certificate import --vault-name $kv -n $demosite1_secret_name -f $site1pem
az keyvault certificate import --vault-name $kv -n $demosite2_secret_name -f $site2pem
# Create private endpoint for the keyvault access
az network private-endpoint create --connection-name tokv -n kvpe --private-connection-resource-id $kv_id -g $aks_rg --subnet PE-Subnet --vnet-name $vnet_name --group-id vault
$pe_ip = (az network private-endpoint show -n kvpe -g $aks_rg | convertfrom-json)
# Create a private dns zone for keyvault DNS resolution
az network private-dns zone create -g $aks_rg -n privatelink.vaultcore.azure.net
# Add a record for keyvault
az network private-dns record-set a add-record -g $aks_rg -z privatelink.vaultcore.azure.net -n $kv -a $pe_ip.customDnsConfigs.ipaddresses
# Link the private dns zone with kube-vnet
az network private-dns link vnet create -g $aks_rg -n kvnetlink -z privatelink.vaultcore.azure.net -v $vnet_name -e false
# Create namespace
kubectl create ns $namespace
# install helm
# https://helm.sh/docs/intro/install/
# Add repo to helm
helm repo add stable https://kubernetes-charts.storage.googleapis.com/
helm repo add csi-secrets-store-provider-azure https://raw.githubusercontent.com/Azure/secrets-store-csi-driver-provider-azure/master/charts
# Update helm repo
helm repo update
# Create internal controller yaml manifest
$internal_controller = @"
controller:
  service:
    loadBalancerIP: 10.240.0.100
    annotations:
      service.beta.kubernetes.io/azure-load-balancer-internal: "true"
"@
# Create a file for the manifest
$internal_controller | Out-File C:\sslingress\internal-controller.yaml
# Install nginx controller using helm
helm install nginx-ingress stable/nginx-ingress --namespace $namespace -f C:\sslingress\internal-controller.yaml --set controller.replicaCount=2 --set controller.nodeSelector."beta\.kubernetes\.io/os"=linux --set defaultBackend.nodeSelector."beta\.kubernetes\.io/os"=linux
# Verify the controller got an ip address
Kubectl get service -n $namespace
# Install csi secret store provider for azure
helm install csi-secrets-store-provider-azure/csi-secrets-store-provider-azure --generate-name --namespace $namespace
# Verify pods for csi
kubectl get pods -n $namespace
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
# Verify the pods are created and are running successfully
kubectl get pods -n $namespace
# Check the secrets are create or not
kubectl get secret -n $namespace
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
