oc exec -n vault vault-0 -- vault secrets enable aws

oc exec -n vault vault-0 -- vault write aws/config/root \
    access_key="YOUR_AWS_ROOT_ACCESS_KEY" \
    secret_key="YOUR_AWS_ROOT_SECRET_KEY" \
    region="us-east-1"
# Recreate the terraform-role that the job calls
oc exec -n vault vault-0 -- vault write aws/roles/terraform-role \
    credential_type=iam_user \
    policy_arns="arn:aws:iam::aws:policy/AdministratorAccess"
