### Automated Cloud Infrastructure Pipeline Runner

This repository contains the architecture and manifests required to automate infrastructure delivery using ephemeral, cloud-native runner nodes. The architecture leverages secure orchestration spaces to check out source code dynamically, run compliance validation, maintain remote state locking, and securely provision resources directly inside **Amazon Web Services (AWS)**. 

### Architecture Workflow

mermaid

graph TD
    subgraph Execution Control Plane
        A[Orchestration Engine / API Server] -->|Apply Manifests| B[Isolated Namespace Worker]
        subgraph Security and Execution Blocks
            B --> C[Secret Management Store]
            B --> D[Automated Deployer Engine]
        end
    end

    subgraph Amazon Web Services AWS
        D -->|1. Authenticate Infrastructure| E[AWS IAM / API Gateway]
        D -->|2. Secure State Exchange| F[S3 Bucket: State Matrix Storage]
        D -->|3. Provision Target Services| G[Managed RDS Database Layers]
    end

    style B fill:#326ce5,stroke:#fff,stroke-width:2mm,color:#fff
    style C fill:#000,stroke:#fff,stroke-width:1mm,color:#fff
    style D fill:#f6a,stroke:#333,stroke-width:1mm
    style F fill:#ff9900,stroke:#333,stroke-width:1mm
    style G fill:#ff9900,stroke:#333,stroke-width:1mm

Use code with caution.

### Core Infrastructure Milestones

* **Decoupled Architecture:** Fully isolated the state management engine and execution pods into dedicated, restricted namespaces.
* **Cross-Platform Security:** Established stable network egress paths out to public cloud provider API interfaces.
* **Remote State Locking:** Successfully implemented a centralized remote state backend architecture utilizing authenticated S3 tracking loops.

### File Manifest Structure

### 1. The Runner Manifest (rds-deployer-job.yaml)

This manifest constructs an ephemeral runtime workspace that automatically checks out source code via an initial file compilation container and executes the plan using an unprivileged, non-root user configuration layout (fsGroup: 1000). 

yaml

---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: terraform-runner
  namespace: vault
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: rds-config
  namespace: vault
data:
  AWS_REGION: "us-east-1"
  TF_STATE_BUCKET: "sp-01102026-aws-kub"
  TF_STATE_KEY: "rds/terraform.tfstate"
---
apiVersion: batch/v1
kind: Job
metadata:
  name: rds-deployer
  namespace: vault
spec:
  template:
    spec:
      serviceAccountName: terraform-runner
      securityContext:
        fsGroup: 1000
      initContainers:
      - name: git-cloner
        image: alpine/git
        args: ["clone", "https://github.com/sprakriy/aws-hybrid-project.git", "/src/aws-hybrid-project"]
        volumeMounts:
        - name: code
          mountPath: /src
      containers:
      - name: terraform-executor
        image: hashicorp/terraform:latest
        workingDir: /src/aws-hybrid-project
        env:
        - name: TF_VAR_db_username
          value: "dbadmin"
        - name: TF_VAR_db_password
          value: "supersecretpassword"
        envFrom:
        - configMapRef:
            name: rds-config
        - secretRef:
            name: aws-creds
        command: ["/bin/sh", "-c"]
        args:
          - |
            set -e
            terraform init \
              -backend-config="bucket=${TF_STATE_BUCKET}" \
              -backend-config="key=${TF_STATE_KEY}" \
              -backend-config="region=${AWS_REGION}"
            terraform apply -auto-approve
        volumeMounts:
        - name: code
          mountPath: /src
      restartPolicy: Never
      volumes:
      - name: code
        emptyDir: {}

Use code with caution.

### Pipeline Execution Guide

### Initialization

Ensure your runtime environment contains the necessary identity provider details before executing the runner script: 

bash

oc create secret generic aws-creds -n vault \
  --from-literal=AWS_ACCESS_KEY_ID="YOUR_AWS_ACCESS_KEY" \
  --from-literal=AWS_SECRET_ACCESS_KEY="YOUR_AWS_SECRET_KEY"

Use code with caution.

### Triggering the Execution Runner

To prevent immutable tracking conflicts with older pipeline execution logs, wipe previous runs from the orchestrator and apply the clean manifest layer: 

bash

# 1. Purge the existing job execution history
oc delete job rds-deployer -n vault --ignore-not-found=true

# 2. Deploy the latest infrastructure manifest configuration
oc apply -f rds-deployer-job.yaml -n vault

# 3. Stream deployment output in real time
oc logs job/rds-deployer -c terraform-executor -n vault -f

Use code with caution.