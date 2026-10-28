Automated Ephemeral Terraform Runner on Kubernetes (k3d + Vault + S3)
An end-to-end GitOps/Kubernetes pattern for executing non-interactive, stateless Terraform deployments and teardowns using dynamic AWS credentials provided by HashiCorp Vault and remote state stored in S3—all running inside the `vault` namespace.
By changing the `GIT_REPO_URL` and target state details in the Kubernetes manifests, you can re-use this pattern for any infrastructure repository.
Architecture Overview
```mermaid
graph TD
    subgraph K3D["k3d Kubernetes Cluster"]
        subgraph VaultNS["vault namespace"]
            Vault["HashiCorp Vault\n(AWS Secrets Engine)"]
            Deployer["Kubernetes Job:\nec2-deployer"]
            Destroyer["Kubernetes Job:\nec2-destroyer"]
            ConfigMap["ConfigMap:\nec2-tf-config\n(Bucket, Key, Region)"]
        end
    end

    subgraph External["External Cloud Infrastructure"]
        S3["AWS S3 Bucket\n(Remote Terraform State)"]
        AWS_IAM["AWS IAM / STS\n(Identity & Access Management)"]
        EC2["AWS EC2 / Target Infrastructure"]
    end

    %% Flow interactions
    ConfigMap -. Inject Config .-> Deployer
    ConfigMap -. Inject Config .-> Destroyer

    Deployer -- 1. Request AWS Creds --> Vault
    Vault -- 2. Create Dynamic IAM User --> AWS_IAM
    Vault -- 3. Access/Secret Keys --> Deployer
    
    Deployer -- 4. Wait 15s (IAM Propagation) --> Deployer
    Deployer -- 5. Clone Target Repo --> Deployer
    Deployer -- 6. terraform init / apply --> S3
    Deployer -- 7. Provision Resources --> EC2

    Destroyer -- 1. Request AWS Creds --> Vault
    Vault -- 2. Create Dynamic IAM User --> AWS_IAM
    Vault -- 3. Access/Secret Keys --> Destroyer
    
    Destroyer -- 4. Wait 15s (IAM Propagation) --> Destroyer
    Destroyer -- 5. Clone Target Repo --> Destroyer
    Destroyer -- 6. terraform init -backend-config --> S3
    Destroyer -- 7. terraform destroy --> EC2
```
Key Lessons Learned
> **CRITICAL: IAM Credentials Propagation Delay**
>
> When Vault generates dynamic IAM credentials (`credential_type = iam-user`), AWS requires a **10–15 second global propagation window** before those temporary access keys are recognized by S3, STS, or EC2 endpoints. Running `terraform init` immediately upon receiving keys from Vault will result in sporadic `403 InvalidClientTokenId` or `AccessDenied` errors. An explicit delay (`sleep 15`) is mandatory prior to execution.
Step 1: Local Environment & Cluster Setup
1. Create k3d Cluster
```bash
k3d cluster create tf-runner-cluster --agents 1
```
2. Create Vault Namespace & Install HashiCorp Vault via Helm
```bash
# Create dedicated vault namespace
kubectl create namespace vault

# Install Vault in dev mode inside the vault namespace
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update

helm install vault hashicorp/vault \
  --namespace vault \
  --set "server.dev.enabled=true" \
  --set "server.dev.devRootToken=root"
```
3. Verify Vault Pod Readiness in `vault` Namespace
```bash
kubectl wait --for=condition=ready pod/vault-0 -n vault --timeout=60s
```
4. Configure Vault AWS Secrets Engine
Exec into the Vault pod inside the `vault` namespace to enable and configure the AWS secrets engine:
```bash
kubectl exec -it vault-0 -n vault -- sh
```
Inside `vault-0`:
```bash
# Enable AWS Secrets Engine
vault secrets enable aws

# Configure AWS Root credentials in Vault (Replace with your AWS admin credentials)
vault write aws/config/root \
    access_key="YOUR_AWS_ROOT_ACCESS_KEY" \
    secret_key="YOUR_AWS_ROOT_SECRET_KEY" \
    region="us-east-1"

# Create a role for Terraform with dynamic IAM user credentials
vault write aws/roles/terraform-role \
    credential_type=iam-user \
    policy_arns="arn:aws:iam::aws:policy/AdministratorAccess"

exit
```
Step 2: Shared ConfigMap (`ec2-tf-config`)
Create the shared ConfigMap in the `vault` namespace containing the remote backend details and target Git repository URL:
```bash
cat <<EOF | kubectl apply -n vault -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: ec2-tf-config
  namespace: vault
data:
  TF_STATE_BUCKET: "your-terraform-state-bucket-name"
  TF_STATE_KEY: "ec2-vault/terraform.tfstate"
  AWS_REGION: "us-east-1"
  GIT_REPO_URL: "https://github.com/your-org/your-tf-repo.git"
EOF
```
Step 3: Deployment Job (`ec2-deployer.yaml`)
This job requests dynamic AWS keys from Vault (`http://localhost:8200` or `http://vault.vault.svc.cluster.local:8200` inside the `vault` namespace), waits 15 seconds for IAM propagation, clones your repo, injects the backend config, and runs `terraform apply`.
```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: ec2-deployer
  namespace: vault
spec:
  ttlSecondsAfterFinished: 300
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: terraform-runner
        image: hashicorp/terraform:latest
        workingDir: /src
        command: ["/bin/sh", "-c"]
        args:
          - |
            set -e

            echo "==> Installing required CLI tooling (curl, git, jq)..."
            apk add --no-cache curl git jq

            echo "==> Fetching dynamic AWS credentials from Vault..."
            VAULT_RESPONSE=$(curl -s --fail \
              --header "X-Vault-Token: root" \
              http://vault.vault.svc.cluster.local:8200/v1/aws/creds/terraform-role)

            export AWS_ACCESS_KEY_ID=$(echo "$VAULT_RESPONSE" | jq -r '.data.access_key')
            export AWS_SECRET_ACCESS_KEY=$(echo "$VAULT_RESPONSE" | jq -r '.data.secret_key')

            echo "==> WAITING 15 Seconds for AWS IAM Global Credential Propagation..."
            sleep 15

            echo "==> Cloning infrastructure repository..."
            git clone "${GIT_REPO_URL}" .

            echo "==> Generating backend configuration..."
            cat <<EOF > backend.hcl
            bucket = "${TF_STATE_BUCKET}"
            key    = "${TF_STATE_KEY}"
            region = "${AWS_REGION}"
            EOF

            echo "==> Initializing Terraform..."
            terraform init -backend-config=backend.hcl

            echo "==> Executing Terraform Apply..."
            terraform apply -auto-approve

        envFrom:
        - configMapRef:
            name: ec2-tf-config
```
Execute deployment and monitor logs:
```bash
kubectl apply -f ec2-deployer.yaml -n vault
kubectl logs -f job/ec2-deployer -n vault
```
Step 4: Destruction Job (`ec2-destroyer.yaml`)
This job connects to the exact same S3 backend using fresh dynamic credentials, waits 15 seconds for IAM propagation, and tears down all infrastructure.
```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: ec2-destroyer
  namespace: vault
spec:
  ttlSecondsAfterFinished: 300
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: terraform-runner
        image: hashicorp/terraform:latest
        workingDir: /src
        command: ["/bin/sh", "-c"]
        args:
          - |
            set -e

            echo "==> Installing required CLI tooling (curl, git, jq)..."
            apk add --no-cache curl git jq

            echo "==> Fetching dynamic AWS credentials from Vault..."
            VAULT_RESPONSE=$(curl -s --fail \
              --header "X-Vault-Token: root" \
              http://vault.vault.svc.cluster.local:8200/v1/aws/creds/terraform-role)

            export AWS_ACCESS_KEY_ID=$(echo "$VAULT_RESPONSE" | jq -r '.data.access_key')
            export AWS_SECRET_ACCESS_KEY=$(echo "$VAULT_RESPONSE" | jq -r '.data.secret_key')

            echo "==> WAITING 15 Seconds for AWS IAM Global Credential Propagation..."
            sleep 15

            echo "==> Cloning infrastructure repository..."
            git clone "${GIT_REPO_URL}" .

            echo "==> Generating backend configuration..."
            cat <<EOF > backend.hcl
            bucket = "${TF_STATE_BUCKET}"
            key    = "${TF_STATE_KEY}"
            region = "${AWS_REGION}"
            EOF

            echo "==> Initializing Terraform..."
            terraform init -backend-config=backend.hcl

            echo "==> Executing Terraform Destroy..."
            terraform destroy -auto-approve

        envFrom:
        - configMapRef:
            name: ec2-tf-config
```
Execute teardown and monitor logs:
```bash
kubectl apply -f ec2-destroyer.yaml -n vault
kubectl logs -f job/ec2-destroyer -n vault
```
